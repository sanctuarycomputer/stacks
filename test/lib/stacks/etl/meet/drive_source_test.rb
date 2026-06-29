require 'test_helper'

class Stacks::Etl::Meet::DriveSourceTest < ActiveSupport::TestCase
  test 'normalizes a Drive transcript doc into segments' do
    file = OpenStruct.new(id: 'doc1', name: 'Gateway sync - Transcript', created_time: '2026-01-01T09:00:00Z')
    svc = mock('drive')
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns("Drew: we should ship\nHugh: agreed, friday")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    yielded = []
    Stacks::Etl::Meet::DriveSource.new('hugh@sanctuary.computer', since: Time.utc(2025, 1, 1)).each_meeting { |n| yielded << n }

    n = yielded.first
    assert_equal 'doc1', n[:external_id]
    assert_equal 2, n[:segments].size
    assert_equal 'Drew', n[:segments].first[:speaker_name]
    assert_equal 'we should ship', n[:segments].first[:text]
    meeting = n[:build_source_record].call(Document.create!(source: :meet, external_id: 'doc1'))
    assert_equal 'doc1', meeting.drive_transcript_doc_id
  end

  test 'accepts a string since and does not raise' do
    file = OpenStruct.new(id: 'doc2', name: 'Sync - Transcript', created_time: '2026-01-01T09:00:00Z')
    svc = mock('drive')
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns("Alice: hello")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    yielded = []
    assert_nothing_raised do
      Stacks::Etl::Meet::DriveSource.new('hugh@sanctuary.computer', since: '2025-01-01T00:00:00Z').each_meeting { |n| yielded << n }
    end
    assert_equal 1, yielded.size
  end
end
