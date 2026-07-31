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

  def make_tracker_with_workstream(tracker_name:, client_name:, code:, rate_tags: [], project_name: nil)
    client = ForecastClient.create!(forecast_id: rand(1_000_000..9_999_999), name: client_name,
                                    archived: false, updated_at: Time.current)
    fp = ForecastProject.create!(forecast_id: rand(1_000_000..9_999_999), name: (project_name || tracker_name),
                                 code: code, client_id: client.forecast_id, archived: false,
                                 tags: rate_tags, updated_at: Time.current)
    # ProjectTracker#validate has_msa_and_sow_links requires MSA/SOW project_tracker_links,
    # which this helper has no need to set up — bypass validation on save, same as
    # test/models/project_tracker_test.rb does for tracker fixtures built without them.
    tracker = ProjectTracker.new(name: tracker_name)
    tracker.save!(validate: false)
    ws = ProjectTrackerForecastProject.create!(project_tracker: tracker, forecast_project_id: fp.forecast_id)
    [tracker, ws, fp, client]
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

  # ---- list_project_trackers ----------------------------------------------
  test "list_project_trackers returns trackers with nested workstreams and rates" do
    tracker, ws, _fp, _client = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Qualitate Inc", code: "QUAL", rate_tags: ["450p/h"])
    resp = Mcp::ListProjectTrackersTool.call(server_context: {})
    row = payload(resp).find { |t| t["id"] == tracker.id }
    assert_equal "Qualitate", row["name"]
    assert_equal "Qualitate Inc", row["client"]
    assert_equal [ws.id], row["workstreams"].map { |w| w["id"] }
    assert_equal [450.0], row["workstreams"].first["rates"]
  end

  test "list_project_trackers filters by case-insensitive name" do
    keep, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Qualitate Inc", code: "QUAL")
    make_tracker_with_workstream(tracker_name: "Other", client_name: "Other Inc", code: "OTHR")
    resp = Mcp::ListProjectTrackersTool.call(name: "qualitate", server_context: {})
    assert_equal [keep.id], payload(resp).map { |t| t["id"] }
  end

  test "list_project_trackers filters by case-insensitive client" do
    keep, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Qualitate Inc", code: "QUAL")
    make_tracker_with_workstream(tracker_name: "Other", client_name: "Other Inc", code: "OTHR")
    resp = Mcp::ListProjectTrackersTool.call(client: "qualitate inc", server_context: {})
    assert_equal [keep.id], payload(resp).map { |t| t["id"] }
  end
end
