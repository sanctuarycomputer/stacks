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

  test 'backfill_meet_all sweeps transcripts, then a gemini_notes sweep with parse_transcript: true' do
    seq = sequence('sweeps')
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entry(mode: :drive)).in_sequence(seq)
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entries(mode: :gemini_notes, until_time: nil, parse_transcript: true)).in_sequence(seq)
    Rake::Task['stacks:etl:backfill_meet_all'].reenable
    Rake::Task['stacks:etl:backfill_meet_all'].invoke('30')
  end

  test 'sync_all invokes sync_meet_all (api) before sync_gemini_notes_all (gemini_notes, parse_transcript: false)' do
    seq = sequence('sync_all_sweeps')
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entry(mode: :api)).in_sequence(seq)
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entries(mode: :gemini_notes, until_time: nil, parse_transcript: false)).in_sequence(seq)
    # Keep the other sync_all steps off the network (they called Google/Anthropic for real
    # and could hang the suite).
    Stacks::Etl::Groups::Connector.any_instance.stubs(:run)
    Stacks::WeeklyShips::Sweep.stubs(:run!).returns(Hash.new(0))
    Stacks::WeeklyShips::Grader.stubs(:run!).returns(Hash.new(0))
    Stacks::Meetings::Sweep.stubs(:run!).returns(Hash.new(0))
    # A failing task would otherwise report itself to the real exceptions thread.
    Stacks::Notifications.expects(:report_exception).never
    # The privacy wall is re-applied after the syncs, for real (not a dry run).
    Stacks::Etl::Reclassifier.expects(:call).with(dry_run: false, mail_review_budget: Stacks::Etl::Reclassifier::NIGHTLY_MAIL_REVIEW_BUDGET).in_sequence(seq).returns(Hash.new(0))
    Rake::Task['stacks:etl:sync_meet_all'].reenable
    Rake::Task['stacks:etl:reclassify_privacy'].reenable
    Rake::Task['stacks:etl:sync_gemini_notes_all'].reenable
    Rake::Task['stacks:etl:match_weekly_ships'].reenable
    Rake::Task['stacks:etl:match_meetings'].reenable
    Rake::Task['stacks:etl:sync_all'].reenable
    Rake::Task['stacks:etl:sync_all'].invoke
  end

  test 'sync_all matches meetings last, after the weekly ships' do
    Stacks::Etl::Meet.stubs(:sweep_all_users!)
    Stacks::Etl::Groups::Connector.any_instance.stubs(:run)
    Stacks::Etl::Reclassifier.stubs(:call).returns(Hash.new(0))
    seq = sequence('matchers')
    Stacks::WeeklyShips::Sweep.expects(:run!).once.in_sequence(seq).returns(Hash.new(0))
    Stacks::WeeklyShips::Grader.expects(:run!).once.in_sequence(seq).returns(Hash.new(0))
    Stacks::Meetings::Sweep.expects(:run!).once.with.in_sequence(seq).returns(Hash.new(0))
    # A failing task would otherwise report itself to the real exceptions thread.
    Stacks::Notifications.expects(:report_exception).never
    %w[sync_meet_all sync_gemini_notes_all sync_google_groups reclassify_privacy match_weekly_ships match_meetings sync_all].each do |name|
      Rake::Task["stacks:etl:#{name}"].reenable
    end
    Rake::Task['stacks:etl:sync_all'].invoke
    assert SystemTask.where(name: 'stacks:etl:match_meetings').exists?
  end

  test 'match_meetings runs the sweep inside a SystemTask, with no limit' do
    Stacks::Meetings::Sweep.expects(:run!).once.with.returns(Hash.new(0).merge(scanned: 2, linked: 1))
    # A failing task would otherwise report itself to the real exceptions thread.
    Stacks::Notifications.expects(:report_exception).never
    Rake::Task['stacks:etl:match_meetings'].reenable
    assert_difference -> { SystemTask.where(name: 'stacks:etl:match_meetings').count }, 1 do
      Rake::Task['stacks:etl:match_meetings'].invoke
    end
    task = SystemTask.where(name: 'stacks:etl:match_meetings').last
    assert task.settled_at.present?
    assert_nil task.notification_id, "expected success"
  end

  test 'match_meetings marks the task errored when meetings failed to match' do
    Stacks::Notifications.stubs(:report_exception).returns(stub(record: nil))
    Stacks::Meetings::Sweep.expects(:run!).returns(Hash.new(0).merge(errored: 2))
    SystemTask.any_instance.expects(:mark_as_error).with { |e| e.message.include?('2 meetings failed to match') }
    SystemTask.any_instance.expects(:mark_as_success).never
    Rake::Task['stacks:etl:match_meetings'].reenable
    Rake::Task['stacks:etl:match_meetings'].invoke
  end

  test 'match_meetings marks the task errored when the sweep raises' do
    Stacks::Notifications.stubs(:report_exception).returns(stub(record: nil))
    Stacks::Meetings::Sweep.expects(:run!).raises(RuntimeError, 'sweep blew up')
    SystemTask.any_instance.expects(:mark_as_error).with { |e| e.message == 'sweep blew up' }
    SystemTask.any_instance.expects(:mark_as_success).never
    Rake::Task['stacks:etl:match_meetings'].reenable
    assert_nothing_raised { Rake::Task['stacks:etl:match_meetings'].invoke }
  end

  test 'match_meetings_preview prints each result and never writes' do
    tracker = ProjectTracker.new(name: 'Harvey Staff Augmentation').tap { |t| t.save!(validate: false) }
    Stacks::Meetings::Sweep.expects(:run!).with(dry_run: true, limit: 3).returns(
      Hash.new(0).merge(scanned: 2, input_tokens: 2000, output_tokens: 200, results: [
        { meeting_id: 11, title: 'Harvey weekly sync', tracker_ids: [tracker.id], confidence: 0.9, rationale: 'Title names the client.' },
        { meeting_id: 12, title: 'Studio standup', tracker_ids: [], confidence: 0.2, rationale: 'Internal.' },
      ]))
    Rake::Task['stacks:etl:match_meetings_preview'].reenable
    out = nil
    assert_no_difference('SystemTask.count') do
      out, = capture_io { Rake::Task['stacks:etl:match_meetings_preview'].invoke('3') }
    end
    lines = out.lines.map(&:chomp)
    assert_equal 'Harvey weekly sync (meeting 11) -> Harvey Staff Augmentation [0.9] Title names the client.', lines[0]
    assert_equal 'Studio standup (meeting 12) -> no project [0.2] Internal.', lines[1]
    assert_equal 'scanned 2, errored 0, tokens in 2000 / out 200 (nothing saved)', lines[2]
  end

  test 'match_meetings_preview defaults to ten meetings' do
    Stacks::Meetings::Sweep.expects(:run!).with(dry_run: true, limit: 10).returns(Hash.new(0).merge(results: []))
    Rake::Task['stacks:etl:match_meetings_preview'].reenable
    assert_output(/\(nothing saved\)$/) { Rake::Task['stacks:etl:match_meetings_preview'].invoke }
  end

  test 'reclassify_privacy[dry_run] previews without a SystemTask' do
    Stacks::Etl::Reclassifier.expects(:call).with(dry_run: true, mail_review_budget: Stacks::Etl::Reclassifier::NIGHTLY_MAIL_REVIEW_BUDGET).returns(Hash.new(0).merge(checked: 3))
    Rake::Task['stacks:etl:reclassify_privacy'].reenable
    assert_no_difference('SystemTask.count') do
      assert_output(/checked: 3/) { Rake::Task['stacks:etl:reclassify_privacy'].invoke('dry_run') }
    end
  end

  test 'reclassify_privacy[unbounded] drains the whole mail backlog in one run' do
    Stacks::Etl::Reclassifier.expects(:call).with(dry_run: false, mail_review_budget: nil).returns(Hash.new(0))
    Rake::Task['stacks:etl:reclassify_privacy'].reenable
    assert_output(//) { Rake::Task['stacks:etl:reclassify_privacy'].invoke('unbounded') }
  end

  test 'match_weekly_ships grades after matching, and a grading failure marks the task errored' do
    seq = sequence('ships')
    Stacks::WeeklyShips::Sweep.expects(:run!).in_sequence(seq).returns(Hash.new(0))
    Stacks::WeeklyShips::Grader.expects(:run!).in_sequence(seq).returns(Hash.new(0).merge(errored: 1))
    SystemTask.any_instance.expects(:mark_as_error).with { |e| e.message.include?('1 failed to grade') }
    SystemTask.any_instance.expects(:mark_as_success).never
    Rake::Task['stacks:etl:match_weekly_ships'].reenable
    Rake::Task['stacks:etl:match_weekly_ships'].invoke
  end

  test 'grade_weekly_ships_preview never writes' do
    Stacks::WeeklyShips::Grader.expects(:run!).with(dry_run: true, limit: 3).returns(Hash.new(0).merge(results: []))
    Rake::Task['stacks:etl:grade_weekly_ships_preview'].reenable
    assert_no_difference('SystemTask.count') do
      assert_output(/graded/) { Rake::Task['stacks:etl:grade_weekly_ships_preview'].invoke('3') }
    end
  end

  test 'grade_weekly_ships_backfill passes the since date and limit, and refuses a bad date' do
    Stacks::WeeklyShips::Grader.expects(:run!).with(since: Time.zone.local(2026, 5, 1), limit: 50).returns(Hash.new(0))
    Rake::Task['stacks:etl:grade_weekly_ships_backfill'].reenable
    assert_output(/\{/) { Rake::Task['stacks:etl:grade_weekly_ships_backfill'].invoke('2026-05-01', '50') }

    Stacks::WeeklyShips::Grader.expects(:run!).never
    Rake::Task['stacks:etl:grade_weekly_ships_backfill'].reenable
    assert_raises(Date::Error) { Rake::Task['stacks:etl:grade_weekly_ships_backfill'].invoke('soon') }
  end

  test 'reclassify_privacy refuses an unknown mode instead of doing a real run' do
    Stacks::Etl::Reclassifier.expects(:call).never
    Rake::Task['stacks:etl:reclassify_privacy'].reenable
    assert_raises(ArgumentError) { Rake::Task['stacks:etl:reclassify_privacy'].invoke('dryrun') }
  end
end
