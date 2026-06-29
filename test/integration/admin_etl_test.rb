require 'test_helper'

class AdminEtlTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "etl_admin_#{SecureRandom.hex(4)}@sanctuary.computer",
      password: 'password12345',
      password_confirmation: 'password12345',
      roles: ['admin']
    )
    sign_in @admin
  end

  test 'meetings index renders under the MCP menu' do
    Meeting.create!(
      meet_conference_record_id: 'conferenceRecords/1',
      title: 'Standup',
      meet_source: :meet_api
    )
    get '/admin/meetings'
    assert_response :success
    assert_includes response.body, 'Standup'
  end

  test 'resolving a mention assigns a contact' do
    doc     = Document.create!(source: :meet, external_id: 'd1')
    chunk   = Chunk.create!(document: doc, position: 0, content: 'x', source: :meet)
    mention = Mention.create!(chunk: chunk, raw_text: 'Drew', status: :unresolved)
    contact = Contact.create!(email: 'drew@sanctuary.computer')
    put "/admin/mentions/#{mention.id}/resolve", params: { contact_id: contact.id }
    assert_equal contact.id, mention.reload.contact_id
    assert mention.reload.resolved?
  end
end
