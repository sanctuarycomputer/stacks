require 'test_helper'

class Stacks::Etl::Meet::AuthTest < ActiveSupport::TestCase
  test 'meet_service impersonates the given sub' do
    creds = mock('creds')
    creds.expects(:sub=).with('organizer@sanctuary.computer')
    creds.expects(:fetch_access_token!)
    Stacks::Utils.stubs(:config).returns(google_oauth2: { service_account: '{}' })
    Google::Auth::ServiceAccountCredentials.stubs(:make_creds).returns(creds)

    service = Stacks::Etl::Meet::Auth.meet_service(sub: 'organizer@sanctuary.computer')
    assert_kind_of Google::Apis::MeetV2::MeetService, service
    assert_equal creds, service.authorization
  end

  test 'drive_service impersonates the given sub' do
    creds = mock('creds')
    creds.expects(:sub=).with('organizer@sanctuary.computer')
    creds.expects(:fetch_access_token!)
    Stacks::Utils.stubs(:config).returns(google_oauth2: { service_account: '{}' })
    Google::Auth::ServiceAccountCredentials.stubs(:make_creds).returns(creds)

    service = Stacks::Etl::Meet::Auth.drive_service(sub: 'organizer@sanctuary.computer')
    assert_kind_of Google::Apis::DriveV3::DriveService, service
    assert_equal creds, service.authorization
  end
end
