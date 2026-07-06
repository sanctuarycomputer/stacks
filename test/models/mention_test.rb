require 'test_helper'

class MentionTest < ActiveSupport::TestCase
  setup do
    @doc = Document.create!(source: :meet, external_id: 'd1')
    @chunk = Chunk.create!(document: @doc, position: 0, content: 'x', source: :meet)
  end

  test 'unresolved scope returns mentions awaiting a contact' do
    u = Mention.create!(chunk: @chunk, raw_text: 'Drew', status: :unresolved)
    Mention.create!(chunk: @chunk, raw_text: 'Hugh', status: :resolved, contact: Contact.create!(email: 'h@x.co'))
    assert_equal [u.id], Mention.unresolved.pluck(:id)
  end
end
