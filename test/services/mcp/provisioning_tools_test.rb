require 'test_helper'

class Mcp::ProvisioningToolsTest < ActiveSupport::TestCase
  # ---- helpers -------------------------------------------------------------
  def make_contributor(email:, name: "Test Human")
    fp = ForecastPerson.create!(forecast_id: rand(1_000_000..9_999_999), first_name: name.split.first,
                                last_name: name.split.last, email: email, archived: false,
                                roles: [], updated_at: Time.current)
    # ForecastPerson#after_create (ensure_contributor_exists!) already provisions the Contributor
    # row for us. Contributor.insert! (bypassing validations/callbacks, and needed on Rails 6.1
    # because it does not auto-set the NOT NULL timestamp columns) would create a second,
    # duplicate Contributor for the same forecast_person_id since there's no unique index to stop
    # it — so we just look up the one the callback already made instead of inserting another.
    [Contributor.find_by!(forecast_person_id: fp.forecast_id), fp]
  end

  def payload(resp)
    JSON.parse(resp.content.first[:text])
  end

  # ---- find_contributor ----------------------------------------------------
  test "find_contributor returns matching contributors by case-insensitive email" do
    c, _fp = make_contributor(email: "hugh@sanctuary.computer", name: "Hugh Person")
    resp = Mcp::FindContributorTool.call(email: "HUGH@Sanctuary.Computer", server_context: {})
    rows = payload(resp)
    assert_equal [c.id], rows.map { |r| r["id"] }
    assert_equal "hugh@sanctuary.computer", rows.first["email"]
  end

  test "find_contributor returns empty array when no match" do
    resp = Mcp::FindContributorTool.call(email: "nobody@example.com", server_context: {})
    assert_equal [], payload(resp)
  end
end
