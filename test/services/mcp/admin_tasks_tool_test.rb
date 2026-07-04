require 'test_helper'

class Mcp::AdminTasksToolTest < ActiveSupport::TestCase
  setup do
    @admin = AdminUser.create!(email: "at#{SecureRandom.hex(2)}@example.com",
                               password: 'password123', password_confirmation: 'password123',
                               roles: ['admin'])
    @other = AdminUser.create!(email: "ot#{SecureRandom.hex(2)}@example.com",
                               password: 'password123', password_confirmation: 'password123',
                               roles: ['admin'])
    [@admin, @other].each do |admin|
      FullTimePeriod.create!(admin_user: admin, started_at: Date.today - 30, ended_at: nil,
                             contributor_type: Enum::ContributorType::FIVE_DAY,
                             expected_utilization: 0.8)
    end
  end

  def task_for(admin, type: :missing_skill_tree)
    StacksTask.new(type: type, subject: admin, owners: [admin])
  end

  def payload_for(resp)
    JSON.parse(resp.content.first[:text])
  end

  test 'returns mapped, sorted tasks with owner emails' do
    enterprise_task = StacksTask.new(type: :needs_archiving, subject: enterprises(:sanctuary),
                                     owners: [@admin])
    Stacks::TaskBuilder.any_instance.stubs(:tasks).returns(
      [enterprise_task, task_for(@other, type: :no_full_time_periods_set), task_for(@admin)]
    )
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(server_context: {}))
    assert_equal 3, payload['count']
    row = payload['tasks'].find { |t| t['type'] == 'missing_skill_tree' }
    assert_equal 'Admin user needs skill tree set', row['task']
    assert_equal 'admin_users', row['subject_class']
    assert_equal @admin.email, row['subject']
    assert_equal false, row['url_external']
    assert_match %r{/admin/admin_users/#{@admin.id}}, row['url']
    assert_equal [@admin.email], row['owners']
    classes = payload['tasks'].map { |t| t['subject_class'] }
    assert_equal classes.sort, classes, 'tasks sorted by subject_class first'
    admin_types = payload['tasks'].select { |t| t['subject_class'] == 'admin_users' }.map { |t| t['type'] }
    assert_equal admin_types.sort, admin_types, 'tasks sorted within subject_class by type'
  end

  test 'subjects without an explicit display branch get a conservative redacted name' do
    task = StacksTask.new(type: :needs_archiving, subject: enterprises(:sanctuary), owners: [@admin])
    Stacks::TaskBuilder.any_instance.stubs(:tasks).returns([task])
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(server_context: {}))
    assert_equal "Enterprise ##{enterprises(:sanctuary).id}", payload['tasks'].first['subject']
  end

  test 'owner param filters via tasks_for with case-insensitive email' do
    Stacks::TaskBuilder.any_instance.expects(:tasks_for).with(@admin).returns([task_for(@admin)])
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(owner: @admin.email.upcase, server_context: {}))
    assert_equal 1, payload['count']
  end

  test 'unknown owner returns an error payload listing valid emails' do
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(owner: 'nobody@nowhere.dev', server_context: {}))
    assert_includes payload['error'], "Unknown owner 'nobody@nowhere.dev'"
    assert_includes payload['error'], @admin.email
  end

  test 'an archived admin is neither a resolvable owner nor listed in the error roster' do
    archived = AdminUser.create!(email: "archived#{SecureRandom.hex(2)}@example.com",
                                 password: 'password123', password_confirmation: 'password123',
                                 roles: ['admin'])
    FullTimePeriod.create!(admin_user: archived, started_at: Date.today - 60,
                           ended_at: Date.today - 30,
                           contributor_type: Enum::ContributorType::FIVE_DAY,
                           expected_utilization: 0.8)

    Stacks::TaskBuilder.any_instance.expects(:tasks_for).never
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(owner: archived.email, server_context: {}))
    assert_includes payload['error'], "Unknown owner '#{archived.email}'"
    roster = payload['error'].sub("Unknown owner '#{archived.email}'.", '')
    refute_includes roster, archived.email
  end

  test 'a task whose mapping raises is skipped with a warning, not fatal' do
    Stacks::TaskBuilder.any_instance.stubs(:tasks).returns([task_for(@admin)])
    StacksTask.any_instance.stubs(:subject_url).raises(RuntimeError, 'boom')
    Rails.logger.expects(:warn).with { |msg| msg.include?('skipping task') }
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['tasks']
  end

  test 'empty queue returns a valid empty payload' do
    Stacks::TaskBuilder.any_instance.stubs(:tasks).returns([])
    payload = payload_for(Mcp::ListOpenAdminTasksTool.call(server_context: {}))
    assert_equal 0, payload['count']
    assert_equal [], payload['tasks']
  end
end
