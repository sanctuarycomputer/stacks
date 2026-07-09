require 'test_helper'

class Stacks::Etl::Groups::GoogleGroupThreadTest < ActiveSupport::TestCase
  test 'Document and Chunk accept the google_groups source' do
    doc = Document.create!(source: :google_groups, external_id: '<root@x>',
                           excluded: :not_excluded, excluded_reason: :none)
    assert doc.google_groups?
    chunk = doc.chunks.create!(source: :google_groups, position: 0, content: 'hello')
    assert chunk.google_groups?
  end

  test 'GoogleGroupThread persists thread metadata keyed on root_message_id' do
    gt = GoogleGroupThread.create!(group_email: 'dev@sanctuary.computer', list_id: 'dev.sanctuary.computer',
                             subject: 'Deploy failed', root_message_id: '<root@x>',
                             message_count: 3, first_message_at: Time.utc(2026, 6, 1),
                             last_message_at: Time.utc(2026, 6, 2))
    assert_equal '<root@x>', gt.root_message_id
    assert_equal 3, gt.message_count
  end
end
