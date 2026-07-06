require 'test_helper'
require 'ostruct'

class Stacks::Etl::Meet::WorkspaceTest < ActiveSupport::TestCase
  test 'lists active org user emails, skipping suspended/archived, lowercased, deduped' do
    page1 = OpenStruct.new(users: [
      OpenStruct.new(primary_email: 'Alexa@sanctuary.computer', suspended: false, archived: false),
      OpenStruct.new(primary_email: 'sus@xxix.co', suspended: true, archived: false),
      OpenStruct.new(primary_email: 'arc@xxix.co', suspended: false, archived: true),
    ], next_page_token: 'p2')
    page2 = OpenStruct.new(users: [
      OpenStruct.new(primary_email: 'andy@xxix.co', suspended: false, archived: false),
      OpenStruct.new(primary_email: 'alexa@sanctuary.computer', suspended: false, archived: false), # dup (case)
    ], next_page_token: nil)

    svc = mock('dir')
    svc.stubs(:list_users).returns(page1, page2)
    Stacks::Etl::Meet::Workspace.stubs(:directory_service).returns(svc)

    assert_equal %w[alexa@sanctuary.computer andy@xxix.co], Stacks::Etl::Meet::Workspace.all_active_user_emails.sort
  end
end
