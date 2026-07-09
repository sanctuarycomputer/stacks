# lib/stacks/etl/groups/groups_source.rb
require 'google/apis/gmail_v1'

module Stacks
  module Etl
    module Groups
      # Crawls every group's traffic out of member mailboxes via the Gmail API.
      # Per group: pick up to K impersonable member mailboxes, search each for the
      # group's mail, dedup messages by RFC822 Message-ID, assemble threads. Memory is
      # bounded to one group's window at a time; groups are yielded lazily by the caller.
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
            crawlers = pick_crawlers(Workspace.members(g[:email]), active)
            next if crawlers.empty?
            by_id = {}
            crawlers.each do |member_email|
              fetch_group_messages(member_email, g[:email]) { |msg| by_id[msg[:message_id]] ||= msg }
            rescue StandardError => e
              Rails.logger.warn("[groups] #{g[:email]} via #{member_email} skipped: #{e.class}: #{e.message.to_s[0, 140]}")
            end
            next if by_id.empty?
            MessageParser.assemble(group_email: g[:email], group_name: g[:name], messages: by_id.values)
                         .each { |n| yield n }
          end
        end

        private

        def active_emails
          Set.new(Stacks::Etl::Meet::Workspace.all_active_user_emails)
        end

        # Owners/managers first, restricted to active internal users we can impersonate.
        def pick_crawlers(members, active)
          usable = members.select { |m| m[:type] == 'USER' && m[:email] && active.include?(m[:email]) }
          owners = usable.select { |m| %w[OWNER MANAGER].include?(m[:role]) }
          (owners + usable).map { |m| m[:email] }.uniq.first(@k)
        end

        def fetch_group_messages(member_email, group_email)
          gmail = Stacks::Etl::Meet::Auth.gmail_service(sub: member_email)
          page = nil
          loop do
            resp = gmail.list_user_messages('me', q: query_for(group_email), max_results: GMAIL_PAGE, page_token: page)
            Array(resp.messages).each do |ref|
              raw = gmail.get_user_message('me', ref.id, format: 'raw').raw
              yield MessageParser.parse(raw)
            rescue StandardError => e
              Rails.logger.warn("[groups] #{group_email} message #{ref.id} skipped: #{e.class}: #{e.message.to_s[0, 140]}")
            end
            page = resp.next_page_token
            break unless page
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
