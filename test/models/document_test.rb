require 'test_helper'

class DocumentTest < ActiveSupport::TestCase
  test 'corpus_eligible scope includes not_excluded and manually_included only' do
    a = Document.create!(source: :meet, external_id: 'a', excluded: :not_excluded)
    b = Document.create!(source: :meet, external_id: 'b', excluded: :manually_included)
    Document.create!(source: :meet, external_id: 'c', excluded: :auto_excluded)
    Document.create!(source: :meet, external_id: 'd', excluded: :manually_excluded)
    assert_equal [a.id, b.id].sort, Document.corpus_eligible.pluck(:id).sort
  end

  test 'source+external_id is unique' do
    Document.create!(source: :meet, external_id: 'x')
    assert_raises(ActiveRecord::RecordNotUnique) { Document.create!(source: :meet, external_id: 'x') }
  end
end
