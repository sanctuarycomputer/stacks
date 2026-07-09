# lib/stacks/etl/groups/groups_source.rb
require 'google/apis/gmail_v1'
require 'set'

module Stacks
  module Etl
    module Groups
      # Crawls every group's traffic out of member mailboxes via the Gmail API.
      #
      # Streaming, memory-bounded design: rather than pull a whole group's year of mail into
      # memory before assembling anything (which silently blocks for ~an hour on a firehose
      # list like admin@ and holds tens of thousands of message bodies at once), we discover
      # thread membership cheaply from the `list` response (Gmail returns a `thread_id` per
      # message for free), then fetch + assemble + YIELD one Gmail thread at a time and free
      # it. Peak memory is a single thread (plus a small per-group set of already-seen ids);
      # Documents land incrementally, so progress is visible and an interrupted run resumes
      # cleanly (ingest is idempotent on the root Message-ID).
      #
      # Cross-mailbox union is approximate under streaming: messages are deduped by RFC822
      # Message-ID and threads by root across the K crawlers, owner/longest-tenured first. For
      # normal list traffic (every member receives every message) each mailbox holds the whole
      # thread, so the first crawler captures it fully and later crawlers dedup away. The only
      # gap is a thread where a later crawler holds messages the first one lacks (a member who
      # joined mid-thread) — those extra messages are dropped rather than merged. That is the
      # deliberate trade for bounded memory + incremental progress.
      class GroupsSource
        DEFAULT_SINCE = 30.days
        GMAIL_PAGE = 100

        def initialize(admin_email:, since: nil, until_time: nil, k: 2)
          @admin_email = admin_email
          @since = coerce(since) || DEFAULT_SINCE.ago
          @until_time = coerce(until_time)
          @k = k
        end

        def each_thread
          active = active_emails
          Workspace.all_groups.each do |g|
            stream_group(g, active) { |doc| yield doc }
          end
        end

        private

        def active_emails
          Set.new(Stacks::Etl::Meet::Workspace.all_active_user_emails)
        end

        # Stream one group's threads, deduping across its K crawler mailboxes. Rescued at two
        # levels: one crawler failing (revoked Gmail access) logs and moves to the next; the
        # whole group failing (deleted mid-run, a Directory members error) logs and yields
        # nothing rather than aborting the run. `yield` stays here — outside every rescue — so
        # a consumer/ingest error still propagates instead of being swallowed.
        def stream_group(g, active)
          crawlers = pick_crawlers(Workspace.members(g[:email]), active)
          return if crawlers.empty?
          seen_msgs = Set.new   # RFC822 Message-IDs already ingested for this group
          seen_roots = Set.new  # thread roots already yielded for this group
          crawlers.each do |member_email|
            each_gmail_thread(member_email, g[:email]) do |messages|
              fresh = messages.reject { |m| m[:message_id].nil? || seen_msgs.include?(m[:message_id]) }
              next if fresh.empty?
              fresh.each { |m| seen_msgs << m[:message_id] }
              MessageParser.assemble(group_email: g[:email], group_name: g[:name], messages: fresh).each do |doc|
                next if seen_roots.include?(doc[:external_id])
                seen_roots << doc[:external_id]
                yield doc
              end
            end
          rescue StandardError => e
            Rails.logger.warn("[groups] #{g[:email]} via #{member_email} skipped: #{e.class}: #{e.message.to_s[0, 140]}")
          end
        rescue StandardError => e
          Rails.logger.warn("[groups] group #{g[:email]} skipped: #{e.class}: #{e.message.to_s[0, 140]}")
        end

        # Owners/managers first, restricted to active internal users we can impersonate.
        def pick_crawlers(members, active)
          usable = members.select { |m| m[:type] == 'USER' && m[:email] && active.include?(m[:email]) }
          owners = usable.select { |m| %w[OWNER MANAGER].include?(m[:role]) }
          (owners + usable).map { |m| m[:email] }.uniq.first(@k)
        end

        # Yields one array of parsed messages per Gmail thread for this crawler's mailbox.
        # Discovery (list) is cheap and gives us the thread_id per message for free, so we
        # bucket message ids by thread WITHOUT fetching bodies, then fetch each thread's bodies
        # only when we're about to hand it off — bounding peak memory to a single thread.
        def each_gmail_thread(member_email, group_email)
          gmail = Stacks::Etl::Meet::Auth.gmail_service(sub: member_email)
          threads = Hash.new { |h, k| h[k] = [] } # thread_id => [gmail message ids]
          page = nil
          loop do
            resp = gmail.list_user_messages('me', q: query_for(group_email), max_results: GMAIL_PAGE, page_token: page)
            Array(resp.messages).each { |ref| threads[ref.thread_id] << ref.id }
            page = resp.next_page_token
            break unless page
          end
          threads.each_value do |gmail_ids|
            msgs = gmail_ids.filter_map do |gid|
              raw = gmail.get_user_message('me', gid, format: 'raw').raw
              MessageParser.parse(raw)
            rescue StandardError => e
              Rails.logger.warn("[groups] #{group_email} message #{gid} skipped: #{e.class}: #{e.message.to_s[0, 140]}")
              nil
            end
            yield msgs unless msgs.empty?
          end
        end

        def query_for(group_email)
          q = "(list:#{group_email} OR to:#{group_email} OR cc:#{group_email})"
          q += " after:#{@since.strftime('%Y/%m/%d')}" if @since
          q += " before:#{@until_time.strftime('%Y/%m/%d')}" if @until_time
          q
        end

        def coerce(t)
          return nil if t.nil?
          t.is_a?(String) ? Time.parse(t) : t
        end
      end
    end
  end
end
