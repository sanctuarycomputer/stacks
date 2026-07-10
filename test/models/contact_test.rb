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

class ContactDedupeTest < ActiveSupport::TestCase
  test 'merges duplicate contacts into the oldest survivor and unions sources' do
    keep = Contact.create!(email: 'merge@gmail.com', sources: ['a'], display_name: 'Keep')
    Contact.create!(email: 'MERGE@gmail.com', sources: ['b'])
    Contact.create!(email: 'Merge@Gmail.com', sources: ['a', 'c'], apollo_id: 'apollo-1')

    result = keep.dedupe!

    assert_equal keep.id, result.id
    assert_equal 1, Contact.where('LOWER(email) = ?', 'merge@gmail.com').count
    assert_equal %w[a b c], result.sources.sort
    assert_equal 'apollo-1', result.apollo_id
    assert_equal 'Keep', result.display_name
  end

  test 'repoints document_contacts before deleting the duplicate (no FK violation)' do
    keep = Contact.create!(email: 'fk@gmail.com', sources: ['a'])
    loser = Contact.create!(email: 'FK@gmail.com', sources: ['b'])
    document = Document.create!(external_id: SecureRandom.hex(8))
    dc = DocumentContact.create!(document: document, contact: loser, role: 'attendee')

    assert_nothing_raised { keep.dedupe! }

    assert_equal keep.id, dc.reload.contact_id
    assert_nil Contact.find_by(id: loser.id)
  end

  test 'collapses references that would collide on the unique index' do
    keep = Contact.create!(email: 'dupdc@gmail.com')
    loser = Contact.create!(email: 'DUPDC@gmail.com')
    document = Document.create!(external_id: SecureRandom.hex(8))
    kept_dc = DocumentContact.create!(document: document, contact: keep, role: 'attendee')
    DocumentContact.create!(document: document, contact: loser, role: 'attendee')

    assert_nothing_raised { keep.dedupe! }

    scope = DocumentContact.where(document_id: document.id, contact_id: keep.id, role: 'attendee')
    assert_equal 1, scope.count
    assert_equal kept_dc.id, scope.first.id
  end

  test 'is a no-op for a contact with no duplicates' do
    solo = Contact.create!(email: 'solo@gmail.com', sources: ['x'])
    assert_equal solo.id, solo.dedupe!.id
    assert_equal 1, Contact.where(email: 'solo@gmail.com').count
  end

  test 'merges source_events from duplicates into the survivor' do
    keep = Contact.create!(
      email: 'events@gmail.com',
      sources: ['a'],
      source_events: { 'a' => [{ 'added_at' => '2026-06-01T00:00:00Z' }] }
    )
    Contact.create!(
      email: 'EVENTS@gmail.com',
      sources: %w[a b],
      source_events: {
        'a' => [{ 'added_at' => '2026-06-02T00:00:00Z' }],
        'b' => [{ 'added_at' => '2026-06-03T00:00:00Z' }],
      }
    )

    result = keep.dedupe!

    assert_equal 2, result.source_events['a'].length
    assert_equal 1, result.source_events['b'].length
    assert_equal(
      %w[2026-06-01T00:00:00Z 2026-06-02T00:00:00Z],
      result.source_events['a'].map { |e| e['added_at'] }
    )
  end

  test 'merges source_events across three duplicates, including empty ones' do
    keep = Contact.create!(
      email: 'tri@gmail.com',
      source_events: { 'a' => [{ 'added_at' => '2026-06-02T00:00:00Z' }] }
    )
    Contact.create!(
      email: 'TRI@gmail.com',
      source_events: {
        'a' => [{ 'added_at' => '2026-06-01T00:00:00Z' }],
        'b' => [{ 'added_at' => '2026-06-03T00:00:00Z' }],
      }
    )
    Contact.create!(email: 'Tri@Gmail.com')

    result = keep.dedupe!

    assert_equal 2, result.source_events['a'].length
    assert_equal 1, result.source_events['b'].length
    assert_equal(
      %w[2026-06-01T00:00:00Z 2026-06-02T00:00:00Z],
      result.source_events['a'].map { |e| e['added_at'] }
    )
  end
end

class ContactSyncToApolloTest < ActiveSupport::TestCase
  test 'merges source_events from the destroyed apollo-duplicate' do
    existing = Contact.create!(
      email: 'other@gmail.com',
      apollo_id: 'apollo-x',
      sources: ['b'],
      source_events: { 'b' => [{ 'added_at' => '2026-06-01T00:00:00Z' }] }
    )
    contact = Contact.create!(
      email: 'me@gmail.com',
      sources: ['a'],
      source_events: { 'a' => [{ 'added_at' => '2026-06-02T00:00:00Z' }] }
    )
    fake_apollo = Object.new
    def fake_apollo.search_by_email(email)
      [{ 'id' => 'apollo-x', 'email' => email }]
    end

    contact.sync_to_apollo!(fake_apollo)
    contact.reload

    assert_equal 'apollo-x', contact.apollo_id
    assert_nil Contact.find_by(id: existing.id)
    assert_equal %w[a b], contact.sources.sort
    assert_equal 1, contact.source_events['b'].length
    assert_equal 1, contact.source_events['a'].length
  end
end

class ContactRansackTest < ActiveSupport::TestCase
  test 'excludes jsonb/array columns from ransackable attributes' do
    refute_includes Contact.ransackable_attributes, 'sources'
    refute_includes Contact.ransackable_attributes, 'metadata'
    refute_includes Contact.ransackable_attributes, 'source_events'
  end
end
