require 'test_helper'

class Stacks::Etl::Meet::SweepTest < ActiveSupport::TestCase
  test 'runs the connector for every user, isolates per-user failures, wraps in a SystemTask' do
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails).returns(%w[a@x.co b@x.co c@x.co])

    ok_conn = mock('ok'); ok_conn.stubs(:run)
    bad_conn = mock('bad'); bad_conn.stubs(:run).raises(StandardError, 'no access')
    Stacks::Etl::Meet::Connector.stubs(:new).returns(ok_conn)
    Stacks::Etl::Meet::Connector.stubs(:new).with(has_entry(admin_email: 'b@x.co')).returns(bad_conn)

    result = Stacks::Etl::Meet.sweep_all_users!(task_name: 'stacks:etl:test_sweep', mode: :api, since: 7.days.ago)

    assert_equal({ ok: 2, failed: 1, total: 3 }, result)
    task = SystemTask.where(name: 'stacks:etl:test_sweep').last
    assert task.settled_at.present?
    assert_nil task.notification_id, 'a per-user failure must not fail the whole task'
  end

  test 'a catastrophic error (e.g. user listing fails) marks the SystemTask as errored' do
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails).raises(StandardError, 'directory down')
    Stacks::Notifications.stubs(:report_exception).returns(OpenStruct.new(record: nil))

    assert_raises(StandardError) do
      Stacks::Etl::Meet.sweep_all_users!(task_name: 'stacks:etl:test_sweep_fail', mode: :api, since: 7.days.ago)
    end
    assert SystemTask.where(name: 'stacks:etl:test_sweep_fail').last.settled_at.present?
  end
end
