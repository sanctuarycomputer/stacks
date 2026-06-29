require 'test_helper'
require 'rake'

class EtlRakeTest < ActiveSupport::TestCase
  setup do
    Stacks::Application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task['stacks:etl:sync_meet'].reenable
  end

  test 'sync_meet runs the connector inside a SystemTask' do
    connector = mock('connector')
    connector.expects(:run).once
    Stacks::Etl::Meet::Connector.expects(:new).with(has_entry(mode: :api)).returns(connector)
    assert_difference -> { SystemTask.where(name: 'stacks:etl:sync_meet').count }, 1 do
      Rake::Task['stacks:etl:sync_meet'].invoke
    end
    task = SystemTask.where(name: 'stacks:etl:sync_meet').last
    assert task.settled_at.present?, "expected settled_at to be set"
    assert_nil task.notification_id, "expected notification_id to be nil (success)"
  end
end
