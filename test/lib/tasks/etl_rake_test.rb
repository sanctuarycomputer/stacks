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
    Rake::Task['stacks:etl:sync_meet_all'].reenable
    Rake::Task['stacks:etl:sync_gemini_notes_all'].reenable
    Rake::Task['stacks:etl:sync_all'].reenable
    Rake::Task['stacks:etl:sync_all'].invoke
  end
end
