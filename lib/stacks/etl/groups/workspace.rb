module Stacks
  module Etl
    module Groups
      # Lists the org's Google Groups and their members via the Admin Directory API,
      # spanning every domain in the account (`customer: 'my_customer'`). Impersonates
      # the admin — group/member metadata is admin-visible, not per-mailbox.
      class Workspace
        ADMIN = 'hugh@sanctuary.computer'.freeze
        PAGE = 200

        def self.all_groups
          svc = service
          out = []
          token = nil
          loop do
            resp = svc.list_groups(customer: 'my_customer', max_results: PAGE, page_token: token)
            (resp.groups || []).each { |g| out << { email: g.email.to_s.downcase, name: g.name } }
            token = resp.next_page_token
            break unless token
          end
          out.uniq { |g| g[:email] }
        end

        def self.members(group_email)
          svc = service
          out = []
          token = nil
          loop do
            resp = svc.list_members(group_email, max_results: PAGE, page_token: token)
            (resp.members || []).each { |m| out << { email: m.email.to_s.downcase, role: m.role, type: m.type } }
            token = resp.next_page_token
            break unless token
          end
          out
        end

        def self.service
          Stacks::Etl::Meet::Auth.directory_group_service(sub: ADMIN)
        end
      end
    end
  end
end
