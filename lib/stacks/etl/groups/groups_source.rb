# lib/stacks/etl/groups/groups_source.rb
require 'google/apis/gmail_v1'
require 'set'

module Stacks
  module Etl
    module Groups
      # Crawls every group's traffic out of member mailboxes via the Gmail API.
      #
      # Streaming, memory-bounded, thread-correct design. The naive approach (pull a whole
      # group's year of mail into memory, then assemble) silently blocks for ~an hour on a
      # firehose list (admin@: ~9,550 msgs/mailbox/yr) and holds tens of thousands of bodies.
      # A tempting shortcut — bucket by Gmail's free `thread_id` and yield per Gmail thread —
      # is WRONG: Gmail splits one logical conversation across several thread_ids (subject
      # drift, long gaps), so replies keyed to the same RFC822 root land in different Gmail
      # threads and would be dropped by the root-level dedup.
      #
      # So we group on the true thread key (RFC822 root) in two cheap passes per mailbox:
      #   1. list + a metadata-only fetch (headers, no body) per message to learn its root_id,
      #      bucketing gmail ids under root_id. Holds only ids + headers.
      #   2. fetch full bodies one root bucket at a time, parse, assemble, YIELD, free.
      # Peak memory is a per-mailbox root index (ids/strings) plus one thread's bodies;
      # Documents land incrementally, so progress is visible and an interrupted run resumes
      # cleanly (ingest is idempotent on the root Message-ID). Cost is ~2x Gmail gets per
      # message (metadata + raw) — an accepted trade for correctness on a one-time backfill.
      #
      # Cross-mailbox union across the K crawlers (owner-first) is still approximate: messages
      # dedup by Message-ID and threads by root, and a later crawler's extra messages on an
      # already-seen root are dropped rather than merged (rare: needs a member holding messages
      # the owner lacks). Within a single mailbox, no messages are lost.
      class GroupsSource
        DEFAULT_SINCE = 30.days
        GMAIL_PAGE = 100
        META_HEADERS = %w[Message-ID References In-Reply-To].freeze

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
            each_logical_thread(member_email, g[:email]) do |messages|
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

        # Yields one array of parsed messages per LOGICAL thread (RFC822 root) for this mailbox.
        # See the class comment for why grouping is on root_id (from a cheap metadata pass), not
        # Gmail's thread_id.
        def each_logical_thread(member_email, group_email)
          gmail = Stacks::Etl::Meet::Auth.gmail_service(sub: member_email)
          roots = {}         # root_id => [gmail message ids]
          seen  = Set.new    # Message-IDs already mapped in THIS mailbox
          page = nil
          loop do
            resp = gmail.list_user_messages('me', q: query_for(group_email), max_results: GMAIL_PAGE, page_token: page)
            Array(resp.messages).each do |ref|
              root, mid = root_for(gmail, ref.id)
              if mid.nil?
                Rails.logger.warn("[groups] #{group_email} message #{ref.id} has no Message-ID header; skipped")
                next
              end
              next if seen.include?(mid)
              seen << mid
              (roots[root] ||= []) << ref.id
            rescue StandardError => e
              Rails.logger.warn("[groups] #{group_email} metadata #{ref.id} skipped: #{e.class}: #{e.message.to_s[0, 140]}")
            end
            page = resp.next_page_token
            break unless page
          end
          # Heartbeat: pass 1 (metadata) can run a while on a firehose mailbox before pass 2
          # yields any Document, so log the tally so a long metadata phase reads as progress.
          Rails.logger.info("[groups] #{group_email} via #{member_email}: #{seen.size} messages across #{roots.size} threads; fetching bodies")
          roots.each_value do |gmail_ids|
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

        # Cheap header-only fetch -> [root_id, message_id] so we can group by the true thread
        # root without pulling message bodies.
        def root_for(gmail, gmail_id)
          meta = gmail.get_user_message('me', gmail_id, format: 'metadata', metadata_headers: META_HEADERS)
          h = header_map(meta)
          mid = h['message-id']
          root = MessageParser.root_id_from(message_id: mid, references: h['references'], in_reply_to: h['in-reply-to'])
          [root, mid.to_s.strip.empty? ? nil : MessageParser.bracket(mid)]
        end

        def header_map(meta)
          Array(meta&.payload&.headers).each_with_object({}) { |hdr, acc| acc[hdr.name.to_s.downcase] = hdr.value }
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
