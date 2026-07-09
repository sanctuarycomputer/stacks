require 'test_helper'

class Stacks::Etl::Groups::RakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?('stacks:etl:sync_google_groups')
    SystemTask.stubs(:create!).returns(stub(mark_as_success: true, mark_as_error: true))
  end

  def reenable(name) = Rake::Task[name].reenable

  test 'sync_google_groups runs the connector (recent, tracked)' do
    conn = mock('conn'); conn.expects(:run)
    Stacks::Etl::Groups::Connector.expects(:new).with(has_entry(admin_email: instance_of(String))).returns(conn)
    reenable('stacks:etl:sync_google_groups')
    Rake::Task['stacks:etl:sync_google_groups'].invoke
  end

  test 'backfill_google_groups passes an unbounded day window with track:false' do
    # A block passed to mocha's expects/stubs is silently ignored in mocha 2.7.1, so a
    # capture-and-assert spy is used to actually verify the args reach Connector#run.
    captured = {}
    conn = Object.new
    conn.define_singleton_method(:run) { |**opts| captured = opts; nil }
    Stacks::Etl::Groups::Connector.stubs(:new).returns(conn)
    reenable('stacks:etl:backfill_google_groups')
    Rake::Task['stacks:etl:backfill_google_groups'].invoke('3650') # 10 years — no cap
    assert_equal false, captured[:track], 'expected track: false'
    assert captured[:since].acts_like?(:time), 'expected since: to be a time value'
    # 3650 days ago must be further in the past than 3000 days ago — proves the day arg
    # flows through UNCAPPED (a clamped 90-day backfill would land well after this).
    assert_operator captured[:since], :<, 3000.days.ago, 'expected an unbounded (far-past) backfill window'
  end
end
