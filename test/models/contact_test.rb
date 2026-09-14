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

class ContactDedupeGhostTest < ActiveSupport::TestCase
  # Fix #1a: dedupe! carries ghost_id and ghost_data (incl. deleted_at) from loser to survivor
  test 'dedupe! carries ghost_id and ghost_data from linked loser to unlinked survivor' do
    survivor = Contact.create!(email: 'ghostmerge@gmail.com', sources: ['a'])
    loser = Contact.create!(
      email: 'GHOSTMERGE@gmail.com',
      sources: ['b'],
      ghost_id: 'g-loser-1',
      ghost_data: {
        'snapshot' => {
          'newsletters' => ['weekly'],
          'deleted_at' => '2026-01-15T00:00:00Z',
          'suppressed' => false
        },
        'synced_at' => '2026-01-10T00:00:00Z'
      }
    )

    result = survivor.dedupe!

    assert_equal survivor.id, result.id
    assert_nil Contact.find_by(id: loser.id)
    assert_equal 'g-loser-1', result.ghost_id
    assert_equal '2026-01-15T00:00:00Z', result.ghost_data.dig('snapshot', 'deleted_at')
    assert_equal ['weekly'], result.ghost_data.dig('snapshot', 'newsletters')
  end

  # Fix #1b: when BOTH have ghost_data and only loser has deleted_at, it survives
  test 'dedupe! preserves deleted_at from loser when survivor ghost_data lacks it' do
    survivor = Contact.create!(
      email: 'bothghost@gmail.com',
      sources: ['a'],
      ghost_id: 'g-survivor-2',
      ghost_data: {
        'snapshot' => { 'newsletters' => ['weekly'], 'suppressed' => false },
        'synced_at' => '2026-01-10T00:00:00Z'
      }
    )
    # loser has a different ghost_id that we shouldn't steal (survivor wins ghost_id tie),
    # but its deleted_at must survive into the carried snapshot
    loser = Contact.create!(
      email: 'BOTHGHOST@gmail.com',
      sources: ['b'],
      ghost_data: {
        'snapshot' => {
          'newsletters' => ['other'],
          'deleted_at' => '2026-02-01T00:00:00Z',
          'suppressed' => false
        }
      }
    )

    result = survivor.dedupe!

    assert_equal survivor.id, result.id
    assert_nil Contact.find_by(id: loser.id)
    # survivor keeps its own ghost_id
    assert_equal 'g-survivor-2', result.ghost_id
    # but loser's deleted_at must be preserved (opt-out must survive any merge direction)
    assert_equal '2026-02-01T00:00:00Z', result.ghost_data.dig('snapshot', 'deleted_at')
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

class ContactSyncToApolloGhostTest < ActiveSupport::TestCase
  # Fix #1c: sync_to_apollo! merge carries ghost_id/ghost_data from fresh_existing onto self
  test 'sync_to_apollo! merge carries ghost_id and ghost_data from colliding contact' do
    existing = Contact.create!(
      email: 'other2@gmail.com',
      apollo_id: 'apollo-ghost',
      sources: ['b'],
      ghost_id: 'g-existing-3',
      ghost_data: {
        'snapshot' => {
          'newsletters' => ['weekly'],
          'deleted_at' => '2026-03-01T00:00:00Z',
          'suppressed' => false
        },
        'synced_at' => '2026-01-10T00:00:00Z'
      }
    )
    contact = Contact.create!(
      email: 'me2@gmail.com',
      sources: ['a']
    )
    fake_apollo = Object.new
    def fake_apollo.search_by_email(email)
      [{ 'id' => 'apollo-ghost', 'email' => email }]
    end

    contact.sync_to_apollo!(fake_apollo)
    contact.reload

    assert_equal 'apollo-ghost', contact.apollo_id
    assert_nil Contact.find_by(id: existing.id)
    assert_equal 'g-existing-3', contact.ghost_id
    assert_equal '2026-03-01T00:00:00Z', contact.ghost_data.dig('snapshot', 'deleted_at')
  end
end

class ContactRansackTest < ActiveSupport::TestCase
  test 'excludes jsonb/array columns from ransackable attributes' do
    refute_includes Contact.ransackable_attributes, 'sources'
    refute_includes Contact.ransackable_attributes, 'metadata'
    refute_includes Contact.ransackable_attributes, 'source_events'
  end
end

class ContactRecordSourceEventsTest < ActiveSupport::TestCase
  test "record_source_events! appends an event per source, even for repeats" do
    contact = Contact.create!(email: "events@example.com", sources: ["newsletter"])
    contact.record_source_events!(["newsletter"])
    contact.record_source_events!(["newsletter", "g3d:ghost"])
    contact.reload
    assert_equal 2, contact.source_events["newsletter"].length
    assert_equal 1, contact.source_events["g3d:ghost"].length
    assert contact.source_events["newsletter"].first["added_at"].present?
  end

  test "ghost scopes filter on ghost_id presence" do
    linked = Contact.create!(email: "linked@example.com", ghost_id: "abc123")
    unlinked = Contact.create!(email: "unlinked@example.com")
    assert_includes Contact.synced_to_ghost, linked
    assert_includes Contact.not_synced_to_ghost, unlinked
    assert_not_includes Contact.synced_to_ghost, unlinked
  end
end
