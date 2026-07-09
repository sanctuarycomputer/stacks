require 'google/apis/meet_v2'
require 'google/apis/drive_v3'
require 'google/apis/calendar_v3'
require 'google/apis/gmail_v1'
require 'google/apis/admin_directory_v1'
require 'googleauth'

module Stacks
  module Etl
    module Meet
      class Auth
        SCOPES = [
          'https://www.googleapis.com/auth/meetings.space.readonly',
          'https://www.googleapis.com/auth/drive.readonly'
        ].freeze
        # Full calendar scope (read-only would be cleaner, but this is the scope the
        # org's service account already has authorized in domain-wide delegation, as
        # used by Stacks::Calendar — avoids needing a new DWD grant).
        CALENDAR_SCOPE = Google::Apis::CalendarV3::AUTH_CALENDAR
        GMAIL_SCOPE = Google::Apis::GmailV1::AUTH_GMAIL_READONLY
        DIRECTORY_GROUP_SCOPES = [
          Google::Apis::AdminDirectoryV1::AUTH_ADMIN_DIRECTORY_GROUP_READONLY,
          Google::Apis::AdminDirectoryV1::AUTH_ADMIN_DIRECTORY_GROUP_MEMBER_READONLY
        ].freeze

        def self.meet_service(sub:)
          service = Google::Apis::MeetV2::MeetService.new
          service.authorization = credentials(sub)
          service
        end

        def self.drive_service(sub:)
          service = Google::Apis::DriveV3::DriveService.new
          service.authorization = credentials(sub)
          service
        end

        def self.calendar_service(sub:)
          service = Google::Apis::CalendarV3::CalendarService.new
          service.authorization = credentials(sub, [CALENDAR_SCOPE])
          service
        end

        def self.gmail_service(sub:)
          service = Google::Apis::GmailV1::GmailService.new
          service.authorization = credentials(sub, [GMAIL_SCOPE])
          service
        end

        def self.directory_group_service(sub:)
          service = Google::Apis::AdminDirectoryV1::DirectoryService.new
          service.authorization = credentials(sub, DIRECTORY_GROUP_SCOPES)
          service
        end

        def self.credentials(sub, scopes = SCOPES)
          creds = Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
            scope: scopes
          )
          creds.sub = sub
          creds.fetch_access_token!
          creds
        end
      end
    end
  end
end
