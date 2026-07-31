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

  # ---- tracker_json enrichment (via list_project_trackers) ------------------
  test "list_project_trackers surfaces budgets, completion, links, and leads" do
    tracker, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL", rate_tags: ["450p/h"])
    tracker.update_columns(budget_low_end: 1000, budget_high_end: 2000, work_completed_at: nil)
    tracker.project_tracker_links.create!(name: "MSA", url: "https://x.test/msa", link_type: :msa)
    tracker.project_tracker_links.create!(name: "SOW", url: "https://x.test/sow", link_type: :sow)
    admin = make_admin(email: "acct@sanctuary.computer")
    tracker.account_lead_periods.create!(admin_user: admin, started_at: Date.today.beginning_of_month, ended_at: nil)

    row = payload(Mcp::ListProjectTrackersTool.call(name: "qualitate", server_context: {})).first
    assert_equal 1000, row["budget_low_end"]
    assert_equal 2000, row["budget_high_end"]
    assert_equal false, row["completed"]
    assert_nil row["work_completed_at"]
    assert_equal "https://x.test/msa", row["msa_url"]
    assert_equal "https://x.test/sow", row["sow_url"]
    assert_equal "acct@sanctuary.computer", row["account_lead"]["email"]
    assert_nil row["project_lead"]
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

  test "ensure_workstream matches an existing code case-insensitively (no duplicate)" do
    tracker, _ws, _fp, _c = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL", rate_tags: ["450p/h"])
    Stacks::Forecast.any_instance.expects(:add_project_rate!).never
    Mcp::WriteGuard.expects(:check!).never

    resp = nil
    assert_no_difference -> { ProjectTrackerForecastProject.count } do
      resp = Mcp::EnsureWorkstreamTool.call(
        project_tracker_id: tracker.id, name: "Qualitate", code: "qual", rate: "450p/h", server_context: {})
    end
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

  # ---- create_recurring_assignment ----------------------------------------
  test "create_recurring_assignment creates a rule with defaults (8h/Mon-Fri/today)" do
    c, fp = make_contributor(email: "hugh@sanctuary.computer")
    _t, ws, _proj, _cl = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")

    resp = Mcp::CreateRecurringAssignmentTool.call(
      contributor_id: c.id, workstream_id: ws.id, server_context: {})
    body = payload(resp)
    assert_equal true, body["created"]
    ra = RecurringAssignment.find(body["after"]["id"])
    assert_equal fp.forecast_id, ra.forecast_person_id
    assert_equal ws.forecast_project_id, ra.forecast_project_id
    assert_equal [1, 2, 3, 4, 5], ra.weekdays
    assert_equal 8.0, ra.allocation_in_hours
    assert_equal Date.today, ra.starts_on
  end

  test "create_recurring_assignment honors weekly cadence and overrides" do
    c, _fp = make_contributor(email: "hugh@sanctuary.computer")
    _t, ws, _proj, _cl = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")

    resp = Mcp::CreateRecurringAssignmentTool.call(
      contributor_id: c.id, workstream_id: ws.id, weekdays: [1], allocation_hours: 4,
      starts_on: "2026-08-03", server_context: {})
    ra = RecurringAssignment.find(payload(resp)["after"]["id"])
    assert_equal [1], ra.weekdays
    assert_equal 4.0, ra.allocation_in_hours
    assert_equal Date.new(2026, 8, 3), ra.starts_on
  end

  test "create_recurring_assignment returns the existing active rule instead of duplicating" do
    c, fp = make_contributor(email: "hugh@sanctuary.computer")
    _t, ws, _proj, _cl = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")
    existing = RecurringAssignment.create!(
      forecast_person_id: fp.forecast_id, forecast_project_id: ws.forecast_project_id,
      allocation: 8 * 3600, weekdays: [1, 2, 3, 4, 5], starts_on: Date.today)

    assert_no_difference -> { RecurringAssignment.count } do
      resp = Mcp::CreateRecurringAssignmentTool.call(
        contributor_id: c.id, workstream_id: ws.id, server_context: {})
      body = payload(resp)
      assert_equal false, body["created"]
      assert_equal existing.id, body["after"]["id"]
    end
  end

  test "create_recurring_assignment rejects an empty or out-of-range weekdays list" do
    c, _fp = make_contributor(email: "hugh@sanctuary.computer")
    _t, ws, _proj, _cl = make_tracker_with_workstream(
      tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")
    resp = Mcp::CreateRecurringAssignmentTool.call(
      contributor_id: c.id, workstream_id: ws.id, weekdays: [9], server_context: {})
    assert_match(/weekdays/i, payload(resp)["error"])
  end

  # ---- find_admin_user -----------------------------------------------------
  def make_admin(email:)
    AdminUser.create!(email: email, password: "password123", password_confirmation: "password123", roles: ["admin"])
  end

  test "find_admin_user matches by case-insensitive email" do
    a = make_admin(email: "lead@sanctuary.computer")
    resp = Mcp::FindAdminUserTool.call(email: "LEAD@Sanctuary.Computer", server_context: {})
    rows = payload(resp)
    assert_equal [a.id], rows.map { |r| r["id"] }
    assert_equal "lead@sanctuary.computer", rows.first["email"]
  end

  test "find_admin_user returns empty array when no match" do
    assert_equal [], payload(Mcp::FindAdminUserTool.call(email: "nobody@example.com", server_context: {}))
  end

  # ---- update_project_tracker ---------------------------------------------
  test "update_project_tracker replaces the MSA link and updates budgets" do
    tracker, _ws, _fp, _c = make_tracker_with_workstream(tracker_name: "Qualitate", client_name: "Q Inc", code: "QUAL")
    tracker.project_tracker_links.create!(name: "MSA", url: "https://old.test/msa", link_type: :msa)
    tracker.project_tracker_links.create!(name: "SOW", url: "https://old.test/sow", link_type: :sow)

    resp = Mcp::UpdateProjectTrackerTool.call(
      project_tracker_id: tracker.id, msa_url: "https://new.test/msa",
      budget_low_end: 500, budget_high_end: 900, server_context: {})
    after = payload(resp)["after"]
    assert_equal "https://new.test/msa", after["msa_url"]
    assert_equal 500, after["budget_low_end"]
    assert_equal 900, after["budget_high_end"]
    assert_equal "https://old.test/sow", after["sow_url"], "unspecified fields unchanged"
  end

  test "update_project_tracker builds an SOW link when none exists" do
    # has_msa_and_sow_links requires BOTH link types to exist before save! will succeed, so an
    # MSA link is seeded here (deviating from the brief's fully-bare fixture) — otherwise the
    # tool's save! would raise on the missing MSA before we ever get to assert on the built SOW.
    tracker = ProjectTracker.new(name: "Bare").tap { |t| t.save!(validate: false) }
    tracker.project_tracker_links.create!(name: "MSA", url: "https://x.test/msa", link_type: :msa)
    resp = Mcp::UpdateProjectTrackerTool.call(project_tracker_id: tracker.id, sow_url: "https://x.test/sow", server_context: {})
    assert_equal "https://x.test/sow", payload(resp)["after"]["sow_url"]
  end

  test "update_project_tracker surfaces budget validation" do
    tracker, = make_tracker_with_workstream(tracker_name: "Q", client_name: "Q Inc", code: "QUAL")
    tracker.project_tracker_links.create!(name: "MSA", url: "https://x/msa", link_type: :msa)
    tracker.project_tracker_links.create!(name: "SOW", url: "https://x/sow", link_type: :sow)
    resp = Mcp::UpdateProjectTrackerTool.call(project_tracker_id: tracker.id, budget_low_end: 900, budget_high_end: 100, server_context: {})
    assert_match(/budget/i, payload(resp)["error"])
  end
end
