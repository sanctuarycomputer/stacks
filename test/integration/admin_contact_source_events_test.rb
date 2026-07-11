require 'test_helper'

class AdminContactSourceEventsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "admin-#{SecureRandom.hex(4)}@example.com",
      password: 'password12345',
      password_confirmation: 'password12345',
      roles: ['admin']
    )
    sign_in @admin
  end

  test 'contact show lists each source with its add count and timestamps' do
    contact = Contact.create!(
      email: 'viewer@example.com',
      sources: ['g3d:family_intelligence:fundraising-viewed'],
      source_events: {
        'g3d:family_intelligence:fundraising-viewed' => [
          { 'added_at' => '2026-06-01T00:00:00Z' },
          { 'added_at' => '2026-06-02T12:30:00Z' },
        ],
      }
    )

    get "/admin/contacts/#{contact.id}"

    assert_response :success
    assert_includes response.body, 'Source Events'
    assert_includes response.body, 'g3d:family_intelligence:fundraising-viewed'
    assert_includes response.body, '2×', 'shows the add count'
    assert_includes response.body, 'Jun 1, 2026', 'shows the first timestamp'
    assert_includes response.body, 'Jun 2, 2026', 'shows the second timestamp'
  end

  test 'contact show notes when there are no source events' do
    contact = Contact.create!(email: 'noevents@example.com')

    get "/admin/contacts/#{contact.id}"

    assert_response :success
    assert_includes response.body, 'No source events recorded yet.'
  end
end
