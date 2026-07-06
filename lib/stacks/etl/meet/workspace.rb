require 'google/apis/admin_directory_v1'
require 'googleauth'

module Stacks
  module Etl
    module Meet
      # Lists the org's Workspace users for the multi-user ETL sweep. Uses
      # `customer: 'my_customer'` so it spans every domain in the account
      # (sanctuary.computer + xxix.co) in one pass, rather than per-domain.
      class Workspace
        ADMIN = 'hugh@sanctuary.computer'.freeze

        # Primary emails of all active (non-suspended, non-archived) users, org-wide.
        def self.all_active_user_emails
          service = directory_service
          emails = []
          token = nil
          loop do
            resp = service.list_users(customer: 'my_customer', max_results: 500, page_token: token)
            (resp.users || []).each do |u|
              next if u.suspended || u.archived
              emails << u.primary_email.downcase if u.primary_email.present?
            end
            token = resp.next_page_token
            break unless token
          end
          emails.uniq
        end

        def self.directory_service
          service = Google::Apis::AdminDirectoryV1::DirectoryService.new
          service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
            scope: Google::Apis::AdminDirectoryV1::AUTH_ADMIN_DIRECTORY_USER_READONLY
          )
          service.authorization.sub = ADMIN
          service.authorization.fetch_access_token!
          service
        end
      end
    end
  end
end
