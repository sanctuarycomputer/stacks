require 'test_helper'

class Mcp::GetDocumentToolTest < ActiveSupport::TestCase
  test 'google_groups doc exposes source + root_message_id (for the Gmail backlink); segments empty' do
    gg = Document.create!(source: :google_groups, external_id: '<root@x>',
                          excluded: :not_excluded, excluded_reason: :none,
                          url: 'https://groups.google.com/a/sanctuary.computer/g/dev', title: 'Deploy chatter')
    gg.chunks.create!(source: :google_groups, position: 0, content: 'the api is down')

    payload = mcp_payload(Mcp::GetDocumentTool.call(id: gg.id, server_context: {}))

    assert_equal 'google_groups', payload['source']
    assert_equal '<root@x>', payload['root_message_id'], 'observe needs the RFC822 root to build the rfc822msgid link'
    assert_equal [], payload['segments'], 'email threads are not speaker-segmented'
    assert_equal 'the api is down', payload['body']
    assert_equal 'https://groups.google.com/a/sanctuary.computer/g/dev', payload['url'], 'url is the Groups-browse link'
  end

  test 'meet doc keeps meeting_key/segments and does NOT expose root_message_id' do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: 'cr/z')
    md = Document.create!(source: :meet, external_id: 'cr/z', source_record: m,
                          excluded: :not_excluded, excluded_reason: :none, title: 'Team sync')
    md.chunks.create!(source: :meet, position: 0, content: 'we shipped it')

    payload = mcp_payload(Mcp::GetDocumentTool.call(id: md.id, server_context: {}))

    assert_equal 'meet', payload['source']
    assert_nil payload['root_message_id'], 'root_message_id is google_groups-only'
    assert_equal md.source_record.id, payload['meeting_key']
  end
end
