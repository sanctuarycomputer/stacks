require 'test_helper'

class Stacks::Etl::Groups::AuthTest < ActiveSupport::TestCase
  test 'gmail_service builds a Gmail client with read-only scope, impersonating the member' do
    fake_creds = Object.new
    Stacks::Etl::Meet::Auth.stubs(:credentials)
      .with('member@sanctuary.computer', [Stacks::Etl::Meet::Auth::GMAIL_SCOPE])
      .returns(fake_creds)
    svc = Stacks::Etl::Meet::Auth.gmail_service(sub: 'member@sanctuary.computer')
    assert_instance_of Google::Apis::GmailV1::GmailService, svc
    assert_equal fake_creds, svc.authorization
  end

  test 'directory_group_service builds a Directory client with group read-only scopes' do
    fake_creds = Object.new
    Stacks::Etl::Meet::Auth.stubs(:credentials)
      .with('admin@sanctuary.computer', Stacks::Etl::Meet::Auth::DIRECTORY_GROUP_SCOPES)
      .returns(fake_creds)
    svc = Stacks::Etl::Meet::Auth.directory_group_service(sub: 'admin@sanctuary.computer')
    assert_instance_of Google::Apis::AdminDirectoryV1::DirectoryService, svc
    assert_equal fake_creds, svc.authorization
  end
end
