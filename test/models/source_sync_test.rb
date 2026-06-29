require 'test_helper'

class SourceSyncTest < ActiveSupport::TestCase
  test 'for returns a singleton per source and advance! stores cursor' do
    s1 = SourceSync.for('meet')
    s2 = SourceSync.for('meet')
    assert_equal s1.id, s2.id
    s1.advance!(cursor: { 'last_end_time' => '2026-06-01T00:00:00Z' }, stats: { 'documents' => 3 })
    assert_equal '2026-06-01T00:00:00Z', SourceSync.for('meet').cursor['last_end_time']
    assert_equal 3, SourceSync.for('meet').stats['documents']
  end
end
