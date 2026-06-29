require 'google/apis/meet_v2'
require 'google/apis/drive_v3'
require 'googleauth'

module Stacks
  module Etl
    module Meet
      class Auth
        SCOPES = [
          'https://www.googleapis.com/auth/meetings.space.readonly',
          'https://www.googleapis.com/auth/drive.readonly'
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

        def self.credentials(sub)
          creds = Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
            scope: SCOPES
          )
          creds.sub = sub
          creds.fetch_access_token!
          creds
        end
      end
    end
  end
end
