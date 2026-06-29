require 'test_helper'

class Stacks::Etl::MentionResolverTest < ActiveSupport::TestCase
  setup do
    @drew = Contact.create!(email: 'drew@sanctuary.computer', display_name: 'Drew Smith')
    @hugh = Contact.create!(email: 'hugh@sanctuary.computer', display_name: 'Hugh Francis')
    @participants = [{ name: 'Drew Smith', contact: @drew }, { name: 'Hugh Francis', contact: @hugh }]
  end

  test 'resolve_email makes/find a contact' do
    c = Stacks::Etl::MentionResolver.resolve_email('guest@gmail.com', name: 'Guest')
    assert_equal 'guest@gmail.com', c.email
  end

  test 'exact display-name match resolves at full confidence' do
    r = Stacks::Etl::MentionResolver.resolve_display_name('drew smith', participants: @participants)
    assert_equal @drew.id, r[:contact].id
    assert_equal 'resolved', r[:status]
    assert_equal 1.0, r[:confidence]
  end

  test 'unique first-name match resolves at partial confidence' do
    r = Stacks::Etl::MentionResolver.resolve_display_name('Drew', participants: @participants)
    assert_equal @drew.id, r[:contact].id
    assert_equal 'resolved', r[:status]
    assert_in_delta 0.6, r[:confidence], 0.001
  end

  test 'no match is unresolved' do
    r = Stacks::Etl::MentionResolver.resolve_display_name('Zoltan', participants: @participants)
    assert_nil r[:contact]
    assert_equal 'unresolved', r[:status]
  end

  test 'multiple partial first-name matches are ambiguous' do
    drew_jones = Contact.create!(email: 'drew.jones@gmail.com', display_name: 'Drew Jones')
    participants = @participants + [{ name: 'Drew Jones', contact: drew_jones }]
    r = Stacks::Etl::MentionResolver.resolve_display_name('Drew', participants: participants)
    assert_nil r[:contact]
    assert_equal 'ambiguous', r[:status]
  end

  test 'does not substring-match a shorter name onto a longer one' do
    christine = Contact.create!(email: 'christine@sanctuary.computer', display_name: 'Christine Lee')
    participants = [{ name: 'Christine Lee', contact: christine }]
    # "Chris" must NOT resolve to "Christine" (substring), nor "an" to "Joanna".
    r = Stacks::Etl::MentionResolver.resolve_display_name('Chris', participants: participants)
    assert_nil r[:contact]
    assert_equal 'unresolved', r[:status]
  end

  test 'a trailing component of a hyphenated name does not mis-resolve (prefer unresolved)' do
    anne = Contact.create!(email: 'anne@sanctuary.computer', display_name: 'Anne-Marie Smith')
    participants = [{ name: 'Anne-Marie Smith', contact: anne }]
    # "Marie" is only the TRAILING segment of "Anne-Marie" — too weak; leave it unresolved.
    assert_equal 'unresolved', Stacks::Etl::MentionResolver.resolve_display_name('Marie', participants: participants)[:status]
    # The full name still matches exactly.
    assert_equal anne.id, Stacks::Etl::MentionResolver.resolve_display_name('Anne-Marie Smith', participants: participants)[:contact].id
  end

  test 'leading-segment match handles unicode en/em dashes, not just ASCII hyphens' do
    am = Contact.create!(email: 'am@sanctuary.computer', display_name: 'Anne–Marie Smith') # en dash
    participants = [{ name: 'Anne–Marie Smith', contact: am }]
    assert_equal am.id, Stacks::Etl::MentionResolver.resolve_display_name('Anne', participants: participants)[:contact].id
    assert_equal 'unresolved', Stacks::Etl::MentionResolver.resolve_display_name('Marie', participants: participants)[:status]
  end

  test 'a leading first name shared by two participants is ambiguous, not a confident wrong pick' do
    aj = Contact.create!(email: 'aj@sanctuary.computer', display_name: 'Anne Jones')
    am = Contact.create!(email: 'am@sanctuary.computer', display_name: 'Anne-Marie Smith')
    participants = [{ name: 'Anne Jones', contact: aj }, { name: 'Anne-Marie Smith', contact: am }]
    # "Anne" leads both "Anne Jones" and "Anne-Marie" -> ambiguous (must NOT resolve to one).
    r = Stacks::Etl::MentionResolver.resolve_display_name('Anne', participants: participants)
    assert_nil r[:contact]
    assert_equal 'ambiguous', r[:status]
  end

  test 'participant with nil contact does not produce a resolved result' do
    participants_with_nil = [{ name: 'Ghost User', contact: nil }]
    r = Stacks::Etl::MentionResolver.resolve_display_name('Ghost User', participants: participants_with_nil)
    assert_equal 'unresolved', r[:status]
    assert_nil r[:contact]
  end
end
