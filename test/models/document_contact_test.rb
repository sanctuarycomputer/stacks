require 'test_helper'

class DocumentContactTest < ActiveSupport::TestCase
  test 'links a document to a contact with a role' do
    doc = Document.create!(source: :meet, external_id: 'd1')
    contact = Contact.create!(email: 'a@b.co')
    dc = DocumentContact.create!(document: doc, contact: contact, email: 'a@b.co', role: 'participant')
    assert_includes doc.reload.contacts, contact
    assert_equal 'participant', dc.role
  end
end
