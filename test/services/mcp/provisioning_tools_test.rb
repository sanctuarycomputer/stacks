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

  # ---- ensure_project_tracker ---------------------------------------------
  test "ensure_project_tracker creates a bare tracker when none exists" do
    # Deliberately unpersisted: this stands in for provision!'s return value only. If it were
    # saved, the tool's own pre-check (`ProjectTracker.where(lower(name) = ...)`, which runs
    # for real even though provision! is mocked) would find it and short-circuit to the
    # "already exists" branch before the mock is ever consulted.
    bare_tracker = ProjectTracker.new(name: "New Co")
    ProjectTracker.expects(:provision!).with(has_entries(name: "New Co")).returns([bare_tracker, ["placeholder MSA"]])
    resp = Mcp::EnsureProjectTrackerTool.call(name: "New Co", server_context: {})
    body = payload(resp)
    assert_equal true, body["created"]
    assert_equal "New Co", body["after"]["name"]
    assert_equal ["placeholder MSA"], body["warnings"]
  end

  test "ensure_project_tracker returns the existing tracker without provisioning" do
    tracker, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Qualitate Inc", code: "QUAL")
    ProjectTracker.expects(:provision!).never
    resp = Mcp::EnsureProjectTrackerTool.call(name: "qualitate", server_context: {})
    body = payload(resp)
    assert_equal false, body["created"]
    assert_equal tracker.id, body["after"]["id"]
  end

  test "ensure_project_tracker errors on an ambiguous name" do
    dup1 = ProjectTracker.new(name: "Dup")
    dup1.save!(validate: false)
    dup2 = ProjectTracker.new(name: "Dup")
    dup2.save!(validate: false)
    ProjectTracker.expects(:provision!).never
    resp = Mcp::EnsureProjectTrackerTool.call(name: "Dup", server_context: {})
    assert_match(/multiple project trackers/i, payload(resp)["error"])
  end

  test "ensure_project_tracker no-op does not consume a write-guard slot" do
    make_tracker_with_workstream(tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")
    Mcp::WriteGuard.expects(:check!).never
    Mcp::EnsureProjectTrackerTool.call(name: "Qualitate", server_context: {})
  end

  # ---- ensure_workstream ---------------------------------------------------
  test "ensure_workstream creates a workstream when the code is absent" do
    tracker = ProjectTracker.new(name: "Qualitate")
    tracker.save!(validate: false)
    fake_ws = ProjectTrackerForecastProject.new(id: 123, project_tracker: tracker, forecast_project_id: 999)
    ProjectTracker.any_instance.expects(:add_workstream!).with(
      name: "Qualitate", code: "QUAL", rate: "450p/h", client_name: "Qualitate Inc"
    ).returns(fake_ws)
    Mcp::ProvisioningSerializers.stubs(:workstream_json).with(fake_ws).returns({ id: 123, code: "QUAL" })

    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Qualitate", code: "QUAL",
      rate: "450p/h", client_name: "Qualitate Inc", server_context: {})
    body = payload(resp)
    assert_equal true, body["created"]
    assert_equal true, body["rate_added"]
  end

  test "ensure_workstream adds a missing rate to an existing workstream" do
    tracker, ws, fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL", rate_tags: ["300p/h"])
    Stacks::Forecast.any_instance.expects(:add_project_rate!).with(fp.forecast_id, "450p/h").returns(true)

    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Qualitate", code: "QUAL", rate: "450p/h", server_context: {})
    body = payload(resp)
    assert_equal false, body["created"]
    assert_equal true, body["rate_added"]
  end

  test "ensure_workstream is a no-op when the rate is already present (no cap, no API)" do
    tracker, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL", rate_tags: ["450p/h"])
    Stacks::Forecast.any_instance.expects(:add_project_rate!).never
    Mcp::WriteGuard.expects(:check!).never

    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Qualitate", code: "QUAL", rate: "450p/h", server_context: {})
    body = payload(resp)
    assert_equal false, body["created"]
    assert_equal false, body["rate_added"]
  end

  test "ensure_workstream surfaces the 'client required' validation for a first workstream" do
    tracker = ProjectTracker.new(name: "Bare")
    tracker.save!(validate: false)
    # add_workstream! raises RecordInvalid when no client is derivable and none is given
    inv = ProjectTracker.new
    inv.errors.add(:base, "A client is required for the first workstream.")
    ProjectTracker.any_instance.expects(:add_workstream!).raises(ActiveRecord::RecordInvalid.new(inv))

    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Bare", code: "BARE", rate: "450p/h", server_context: {})
    assert_match(/client is required/i, payload(resp)["error"])
  end

  test "ensure_workstream rejects a non-positive rate before any work" do
    tracker = ProjectTracker.new(name: "Qualitate")
    tracker.save!(validate: false)
    ProjectTracker.any_instance.expects(:add_workstream!).never
    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: tracker.id, name: "Q", code: "QUAL", rate: "0", server_context: {})
    assert_match(/rate must be a positive/i, payload(resp)["error"])
  end

  test "ensure_workstream reports a missing tracker cleanly" do
    resp = Mcp::EnsureWorkstreamTool.call(
      project_tracker_id: 999_999, name: "Q", code: "QUAL", rate: "450p/h", server_context: {})
    assert_match(/not found/i, payload(resp)["error"])
  end
end
