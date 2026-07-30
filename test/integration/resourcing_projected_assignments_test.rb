require "test_helper"

class ResourcingProjectedAssignmentsTest < ActionDispatch::IntegrationTest
  HEADERS = { "Content-Type" => "application/json", "Accept" => "application/json" }.freeze

  def auth_headers
    HEADERS.merge("X-Api-Key" => Stacks::Utils.config[:stacks][:private_api_key])
  end

  def tracker(runn_project_id: 91_100)
    RunnProject.find_or_create_by!(runn_id: runn_project_id) { |rp| rp.name = "RP#{runn_project_id}"; rp.data = {} }
    t = ProjectTracker.new(name: "T", runn_project_id: runn_project_id)
    t.save(validate: false)
    t
  end

  def contributor_for(runn_id, email: "c#{runn_id}@example.com")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    Contributor.create!(forecast_person: fp)
  end

  def people_stub(runn_id, email: "c#{runn_id}@example.com")
    [{ "id" => runn_id, "email" => email, "isArchived" => false }]
  end

  def body(overrides = {})
    { contributor_id: @contributor.id, runn_role_id: 7, project_tracker_id: @tr.id,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480, kind: "work" }.merge(overrides)
  end

  setup do
    Rails.cache.delete("mcp_write_count:#{Time.zone.today.iso8601}")
    @tr = tracker
    @contributor = contributor_for(10)
  end

  test "PUT without X-Api-Key returns 403" do
    put "/api/v1/resourcing/projected_assignments/some:key", headers: HEADERS, params: body.to_json
    assert_response :forbidden
  end

  test "PUT upserts the row and applies through to Runn" do
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([])
    Stacks::Runn.any_instance.stubs(:get_leave_for_person).returns([])
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.expects(:create_assignment).once.returns([{ "id" => 5001 }])
    put "/api/v1/resourcing/projected_assignments/sweep:extrapolate:10:#{@tr.id}",
      headers: auth_headers, params: body.to_json
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "applied", json["status"]
    row = ProjectedAssignment.find_by(source_key: "sweep:extrapolate:10:#{@tr.id}")
    assert_equal [5001], row.runn_assignment_ids
  end

  test "PUT rejects an out-of-range minutes_per_day with 422 and no Runn write" do
    Stacks::Runn.any_instance.expects(:create_assignment).never
    put "/api/v1/resourcing/projected_assignments/bad:key",
      headers: auth_headers, params: body(minutes_per_day: 5000).to_json
    assert_response :unprocessable_entity
  end

  test "PUT ?preview=true writes nothing to Runn" do
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([])
    Stacks::Runn.any_instance.stubs(:get_leave_for_person).returns([])
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.expects(:create_assignment).never
    put "/api/v1/resourcing/projected_assignments/preview:key?preview=true",
      headers: auth_headers, params: body.to_json
    assert_response :success
    assert_equal "preview", JSON.parse(response.body)["status"]
  end

  test "PUT returns 409 on a CAS conflict" do
    marker = Resourcing::WriteThrough.provenance_marker("cas:key")
    ProjectedAssignment.create!(source_key: "cas:key", project_tracker: @tr, contributor: @contributor, runn_role_id: 7,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480, kind: "work",
      runn_assignment_ids: [5001],
      last_synced_runn_state: [{ "personId" => 10, "projectId" => 91_100, "roleId" => 7,
        "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "id" => 5001, "note" => marker }])
    # human moved it in Runn
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([{ "id" => 5001, "personId" => 10, "projectId" => 91_100,
      "roleId" => 7, "startDate" => "2030-05-01", "endDate" => "2030-05-10", "minutesPerDay" => 480, "note" => marker }])
    Stacks::Runn.any_instance.stubs(:get_leave_for_person).returns([])
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.expects(:create_assignment).never
    put "/api/v1/resourcing/projected_assignments/cas:key",
      headers: auth_headers, params: body(end_date: "2030-06-15").to_json
    assert_response :conflict
    assert_equal "conflict", JSON.parse(response.body)["status"]
  end

  test "DELETE removes the row and is idempotent" do
    ProjectedAssignment.create!(source_key: "del:key", project_tracker: @tr, contributor: @contributor,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 0, kind: "time_off")
    delete "/api/v1/resourcing/projected_assignments/del:key", headers: auth_headers
    assert_response :success
    assert_nil ProjectedAssignment.find_by(source_key: "del:key")
    delete "/api/v1/resourcing/projected_assignments/del:key", headers: auth_headers
    assert_response :success # idempotent
  end

  test "DELETE without X-Api-Key returns 403" do
    delete "/api/v1/resourcing/projected_assignments/x:key", headers: HEADERS
    assert_response :forbidden
  end

  test "DELETE ?archive_runn=true deletes owned Runn assignments then the row" do
    marker = Resourcing::WriteThrough.provenance_marker("arch:key")
    ProjectedAssignment.create!(source_key: "arch:key", project_tracker: @tr, contributor: @contributor, runn_role_id: 7,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480, kind: "work",
      runn_assignment_ids: [5001],
      last_synced_runn_state: [{ "personId" => 10, "projectId" => 91_100, "roleId" => 7,
        "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "id" => 5001, "note" => marker }])
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([{ "id" => 5001, "personId" => 10, "projectId" => 91_100,
      "roleId" => 7, "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "note" => marker }])
    Stacks::Runn.any_instance.expects(:delete_assignment).once.with(5001).returns({})
    delete "/api/v1/resourcing/projected_assignments/arch:key?archive_runn=true", headers: auth_headers
    assert_response :success
    assert_nil ProjectedAssignment.find_by(source_key: "arch:key")
  end

  test "DELETE ?archive_runn=true returns 409 and keeps the (unmodified) row when a human edited Runn" do
    marker = Resourcing::WriteThrough.provenance_marker("arch2:key")
    ProjectedAssignment.create!(source_key: "arch2:key", project_tracker: @tr, contributor: @contributor, runn_role_id: 7,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480, kind: "work",
      runn_assignment_ids: [5001],
      last_synced_runn_state: [{ "personId" => 10, "projectId" => 91_100, "roleId" => 7,
        "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "id" => 5001, "note" => marker }])
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([{ "id" => 5001, "personId" => 10, "projectId" => 91_100,
      "roleId" => 7, "startDate" => "2030-05-01", "endDate" => "2030-05-20", "minutesPerDay" => 480, "note" => marker }])
    Stacks::Runn.any_instance.expects(:delete_assignment).never
    delete "/api/v1/resourcing/projected_assignments/arch2:key?archive_runn=true", headers: auth_headers
    assert_response :conflict
    kept = ProjectedAssignment.find_by(source_key: "arch2:key")
    assert kept.present?
    assert_equal "work", kept.kind   # the bug fix: row is NOT corrupted on conflict
  end

  test "POST batch applies each item and reports per-item status" do
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([])
    Stacks::Runn.any_instance.stubs(:get_leave_for_person).returns([])
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.stubs(:create_assignment).returns([{ "id" => 5001 }])
    items = [
      body.merge(source_key: "batch:1"),
      body(minutes_per_day: 9999).merge(source_key: "batch:bad"),
    ]
    post "/api/v1/resourcing/projected_assignments/batch",
      headers: auth_headers, params: { items: items }.to_json
    assert_response :success
    results = JSON.parse(response.body)["results"].index_by { |r| r["source_key"] }
    assert_equal "applied", results["batch:1"]["status"]
    assert_equal "invalid", results["batch:bad"]["status"]
  end

  test "POST batch marks remaining items deferred when WriteGuard cap is hit" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    store.write("mcp_write_count:#{Time.zone.today.iso8601}", Mcp::WriteGuard::DAILY_CAP)
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([])
    Stacks::Runn.any_instance.stubs(:get_leave_for_person).returns([])
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.expects(:create_assignment).never
    items = [body.merge(source_key: "over:1"), body.merge(source_key: "over:2")]
    post "/api/v1/resourcing/projected_assignments/batch",
      headers: auth_headers, params: { items: items }.to_json
    assert_response :success
    statuses = JSON.parse(response.body)["results"].map { |r| r["status"] }
    assert statuses.all? { |s| s == "deferred" }
  end
end
