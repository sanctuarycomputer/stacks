require 'test_helper'

class ContactResolveEmailTest < ActiveSupport::TestCase
  test 'creates a contact for an unknown email and tags the etl:meet source' do
    c = Contact.resolve_email('New.Person@sanctuary.computer', name: 'New Person')
    assert_equal 'new.person@sanctuary.computer', c.email
    assert_equal 'New Person', c.display_name
    assert_includes c.sources, 'etl:meet'
  end

  test 'finds an existing contact case-insensitively and adds the etl:meet source' do
    existing = Contact.create!(email: 'dup@gmail.com', sources: ['xxix:newsletter'])
    c = Contact.resolve_email('DUP@gmail.com', name: 'Dup')
    assert_equal existing.id, c.id
    assert_includes c.sources, 'etl:meet'
    assert_includes c.sources, 'xxix:newsletter'
  end

  test 'fills a blank display_name on an existing contact' do
    Contact.create!(email: 'blank@gmail.com', sources: ['x'])
    c = Contact.resolve_email('blank@gmail.com', name: 'Now Named')
    assert_equal 'Now Named', c.display_name
  end

  test 'does not overwrite an existing display_name' do
    Contact.create!(email: 'named@gmail.com', display_name: 'Original')
    c = Contact.resolve_email('named@gmail.com', name: 'Different')
    assert_equal 'Original', c.display_name
  end

  test 'returns nil for a malformed email instead of raising' do
    assert_nil Contact.resolve_email('not-an-email')
    assert_nil Contact.resolve_email('')
    assert_nil Contact.resolve_email(nil)
  end
end
