require "test_helper"

class SystemModelTest < ActiveSupport::TestCase
  def sys
    @sys ||= System.first_or_create!(settings: {})
  end

  test "grants flag: blank stored value reads false through the predicate, not truthy" do
    sys.update!(ghost_newsletter_grants_enabled: "")
    # The bare Storext reader returns "" here, which is truthy in Ruby. The predicate
    # is the only safe accessor, and it is what the sweep must use.
    refute sys.ghost_newsletter_grants_enabled?
  end

  test "grants flag coerces the values an HTML form can actually send" do
    { "0" => false, "1" => true, "" => false }.each do |stored, expected|
      sys.update!(ghost_newsletter_grants_enabled: stored)
      assert_equal expected, sys.ghost_newsletter_grants_enabled?, "stored #{stored.inspect}"
    end
  end

  test "write budget never returns a value that raises on comparison" do
    ["", "abc", nil, "0", "-5"].each do |stored|
      sys.update!(ghost_sweep_write_budget: stored)
      budget = sys.ghost_sweep_write_budget_clamped
      assert_kind_of Integer, budget, "stored #{stored.inspect}"
      assert_operator budget, :>=, 1, "stored #{stored.inspect}"
    end
    sys.update!(ghost_sweep_write_budget: "3000")
    assert_equal 3000, sys.ghost_sweep_write_budget_clamped
  end

  test "prefix map rejects blank values and downcases keys" do
    # source_prefix always yields a lowercase key, so a map key saved as "Index" by
    # any path other than the admin form would silently never match.
    sys.update!(ghost_newsletter_prefix_map: { "Index" => "nl-1", "xxix" => "" })
    assert_equal({ "index" => "nl-1" }, sys.ghost_newsletter_prefix_map_clean)
  end

  test "prefix map must be assigned wholesale; in-place mutation does not persist" do
    sys.update!(ghost_newsletter_prefix_map: { "index" => "nl-1" })
    sys.ghost_newsletter_prefix_map["xxix"] = "nl-2"
    sys.save!
    assert_equal({ "index" => "nl-1" }, sys.reload.ghost_newsletter_prefix_map)
  end
end
