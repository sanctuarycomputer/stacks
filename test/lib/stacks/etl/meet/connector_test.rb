require 'test_helper'

class Stacks::Etl::Meet::ConnectorTest < ActiveSupport::TestCase
  setup { Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1) }

  def normalized(id, title, pcount)
    {
      external_id: id, title: title, url: 'http://x', occurred_at: Time.utc(2026, 1, 1), content_hash: id,
      contacts: Array.new(pcount) { |i| { email: "p#{i}@x.co", name: "P#{i}", role: 'participant' } },
      segments: [{ speaker_name: 'P0', speaker_email: 'p0@x.co', text: 'decision text', started_at: Time.utc(2026, 1, 1) }],
      raw_metadata: {}, build_source_record: ->(_doc) { nil }
    }
  end

  test 'api mode ingests and classifies a 1:1 as excluded' do
    source = mock('source')
    source.stubs(:each_meeting).multiple_yields([normalized('m1', 'Gateway kickoff', 5)], [normalized('m2', 'Drew 1:1', 2)])
    Stacks::Etl::Meet::MeetApiSource.stubs(:new).returns(source)

    Stacks::Etl::Meet::Connector.new(admin_email: 'hugh@sanctuary.computer', mode: :api).run

    assert Document.find_by!(external_id: 'm1').not_excluded?
    m2 = Document.find_by!(external_id: 'm2')
    assert m2.auto_excluded?
    assert m2.reason_one_on_one?
    assert_equal 0, m2.chunks.count
  end

  test 'classifies on real participant_count, not contacts.size (big meeting, few speakers != 1:1)' do
    # 6-person meeting where Calendar enrichment missed, so contacts fell back to the 2
    # distinct speakers. participant_count=6 must keep it OUT of the 1:1 exclusion.
    n = normalized('m3', 'Roadmap planning', 2).merge(participant_count: 6)
    source = mock('source')
    source.stubs(:each_meeting).multiple_yields([n])
    Stacks::Etl::Meet::MeetApiSource.stubs(:new).returns(source)

    Stacks::Etl::Meet::Connector.new(admin_email: 'hugh@sanctuary.computer', mode: :api).run
    assert Document.find_by!(external_id: 'm3').not_excluded?
  end
end
