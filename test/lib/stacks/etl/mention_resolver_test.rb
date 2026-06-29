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
end
