require 'test_helper'
require 'ostruct'

class Stacks::Etl::Groups::WorkspaceTest < ActiveSupport::TestCase
  test 'all_groups pages across the customer and downcases emails' do
    svc = mock('dir')
    svc.stubs(:list_groups).with(customer: 'my_customer', max_results: 200, page_token: nil)
       .returns(OpenStruct.new(groups: [OpenStruct.new(email: 'Dev@sanctuary.computer', name: 'Dev')], next_page_token: 't'))
    svc.stubs(:list_groups).with(customer: 'my_customer', max_results: 200, page_token: 't')
       .returns(OpenStruct.new(groups: [OpenStruct.new(email: 'info@index-space.org', name: 'Info')], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:directory_group_service).with(sub: 'hugh@sanctuary.computer').returns(svc)

    groups = Stacks::Etl::Groups::Workspace.all_groups
    assert_equal [{ email: 'dev@sanctuary.computer', name: 'Dev' },
                  { email: 'info@index-space.org', name: 'Info' }], groups
  end

  test 'members returns email/role/type tuples' do
    svc = mock('dir')
    svc.stubs(:list_members).with('dev@sanctuary.computer', max_results: 200, page_token: nil)
       .returns(OpenStruct.new(members: [
         OpenStruct.new(email: 'Alice@sanctuary.computer', role: 'OWNER', type: 'USER')
       ], next_page_token: 'p'))
    svc.stubs(:list_members).with('dev@sanctuary.computer', max_results: 200, page_token: 'p')
       .returns(OpenStruct.new(members: [
         OpenStruct.new(email: 'nested@x.com', role: 'MEMBER', type: 'GROUP')
       ], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:directory_group_service).with(sub: 'hugh@sanctuary.computer').returns(svc)

    members = Stacks::Etl::Groups::Workspace.members('dev@sanctuary.computer')
    assert_equal [{ email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
                  { email: 'nested@x.com', role: 'MEMBER', type: 'GROUP' }], members
  end
end
