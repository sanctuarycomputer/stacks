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

  # a historical live Runn assignment for the person, used to supply role_id
  # resolution for brand-new rows (which own nothing yet).
  def prior_assignment_stub(person: 10, role: 7, project: 91_100)
    [{ "id" => 4000, "personId" => person, "projectId" => project, "roleId" => role,
       "startDate" => "2029-01-01", "endDate" => "2029-01-31", "minutesPerDay" => 480, "note" => "" }]
  end

  def body(overrides = {})
    { contributor_id: @contributor.id, project_tracker_id: @tr.id,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480 }.merge(overrides)
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
    Stacks::Runn.any_instance.stubs(:get_assignments).returns(prior_assignment_stub)
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.expects(:create_assignment).once.returns({ "id" => 5001 })
    put "/api/v1/resourcing/projected_assignments/sweep:extrapolate:10:#{@tr.id}",
      headers: auth_headers, params: body.to_json
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "applied", json["status"]
    row = ProjectedAssignment.find_by(source_key: "sweep:extrapolate:10:#{@tr.id}")
    assert_equal 5001, row.runn_assignment_id
  end

  test "PUT rejects an out-of-range minutes_per_day with 422 and no Runn write" do
    Stacks::Runn.any_instance.expects(:create_assignment).never
    put "/api/v1/resourcing/projected_assignments/bad:key",
      headers: auth_headers, params: body(minutes_per_day: 5000).to_json
    assert_response :unprocessable_entity
  end

  test "PUT ?preview=true writes nothing to Runn" do
    Stacks::Runn.any_instance.stubs(:get_assignments).returns(prior_assignment_stub)
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.expects(:create_assignment).never
    put "/api/v1/resourcing/projected_assignments/preview:key?preview=true",
      headers: auth_headers, params: body.to_json
    assert_response :success
    assert_equal "preview", JSON.parse(response.body)["status"]
  end

  test "PUT returns 409 on a CAS conflict" do
    marker = Resourcing::WriteThrough.provenance_marker("cas:key")
    ProjectedAssignment.create!(source_key: "cas:key", project_tracker: @tr, contributor: @contributor,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480,
      runn_assignment_id: 5001,
      last_synced_runn_state: { "personId" => 10, "projectId" => 91_100, "roleId" => 7,
        "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "id" => 5001, "note" => marker })
    # human moved it in Runn
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([{ "id" => 5001, "personId" => 10, "projectId" => 91_100,
      "roleId" => 7, "startDate" => "2030-05-01", "endDate" => "2030-05-10", "minutesPerDay" => 480, "note" => marker }])
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.expects(:create_assignment).never
    put "/api/v1/resourcing/projected_assignments/cas:key",
      headers: auth_headers, params: body(end_date: "2030-06-15").to_json
    assert_response :conflict
    assert_equal "conflict", JSON.parse(response.body)["status"]
  end

  test "PUT returns 409 on a provenance conflict (marker lost)" do
    ProjectedAssignment.create!(source_key: "prov:key", project_tracker: @tr, contributor: @contributor,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480,
      runn_assignment_id: 5001,
      last_synced_runn_state: { "personId" => 10, "projectId" => 91_100, "roleId" => 7,
        "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "id" => 5001,
        "note" => Resourcing::WriteThrough.provenance_marker("prov:key") })
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([{ "id" => 5001, "personId" => 10, "projectId" => 91_100,
      "roleId" => 7, "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480,
      "note" => "hand-edited by a human" }])
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.expects(:create_assignment).never
    put "/api/v1/resourcing/projected_assignments/prov:key",
      headers: auth_headers, params: body(end_date: "2030-06-15").to_json
    assert_response :conflict
  end

  test "PUT replace (shorten): creates the new assignment then deletes the old, updating ownership" do
    marker = Resourcing::WriteThrough.provenance_marker("shorten:key")
    ProjectedAssignment.create!(source_key: "shorten:key", project_tracker: @tr, contributor: @contributor,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480,
      runn_assignment_id: 5001,
      last_synced_runn_state: { "personId" => 10, "projectId" => 91_100, "roleId" => 7,
        "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "id" => 5001, "note" => marker })
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([{ "id" => 5001, "personId" => 10, "projectId" => 91_100,
      "roleId" => 7, "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "note" => marker }])
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    seq = sequence("apply")
    Stacks::Runn.any_instance.expects(:create_assignment).once.in_sequence(seq).returns({ "id" => 5002 })
    Stacks::Runn.any_instance.expects(:delete_assignment).once.in_sequence(seq).with(5001).returns({})
    put "/api/v1/resourcing/projected_assignments/shorten:key",
      headers: auth_headers, params: body(end_date: "2030-05-20").to_json
    assert_response :success
    row = ProjectedAssignment.find_by(source_key: "shorten:key")
    assert_equal 5002, row.runn_assignment_id
  end

  test "PUT returns 422 when the contributor has no unique active Runn person" do
    Stacks::Runn.any_instance.stubs(:get_people).returns([])
    Stacks::Runn.any_instance.expects(:create_assignment).never
    put "/api/v1/resourcing/projected_assignments/unresolved:key",
      headers: auth_headers, params: body.to_json
    assert_response :unprocessable_entity
  end

  test "PUT returns 422 when no Runn role can be resolved for a brand-new row" do
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([])
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.expects(:create_assignment).never
    put "/api/v1/resourcing/projected_assignments/norole:key",
      headers: auth_headers, params: body.to_json
    assert_response :unprocessable_entity
  end

  test "DELETE removes the row and is idempotent" do
    ProjectedAssignment.create!(source_key: "del:key", project_tracker: @tr, contributor: @contributor,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 0)
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

  test "DELETE ?archive_runn=true deletes the owned Runn assignment then the row" do
    marker = Resourcing::WriteThrough.provenance_marker("arch:key")
    ProjectedAssignment.create!(source_key: "arch:key", project_tracker: @tr, contributor: @contributor,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480,
      runn_assignment_id: 5001,
      last_synced_runn_state: { "personId" => 10, "projectId" => 91_100, "roleId" => 7,
        "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "id" => 5001, "note" => marker })
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([{ "id" => 5001, "personId" => 10, "projectId" => 91_100,
      "roleId" => 7, "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "note" => marker }])
    Stacks::Runn.any_instance.expects(:delete_assignment).once.with(5001).returns({})
    delete "/api/v1/resourcing/projected_assignments/arch:key?archive_runn=true", headers: auth_headers
    assert_response :success
    assert_nil ProjectedAssignment.find_by(source_key: "arch:key")
  end

  test "DELETE ?archive_runn=true returns 409 and keeps the (unmodified) row when a human edited Runn" do
    marker = Resourcing::WriteThrough.provenance_marker("arch2:key")
    ProjectedAssignment.create!(source_key: "arch2:key", project_tracker: @tr, contributor: @contributor,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480,
      runn_assignment_id: 5001,
      last_synced_runn_state: { "personId" => 10, "projectId" => 91_100, "roleId" => 7,
        "startDate" => "2030-05-01", "endDate" => "2030-05-31", "minutesPerDay" => 480, "id" => 5001, "note" => marker })
    Stacks::Runn.any_instance.stubs(:get_assignments).returns([{ "id" => 5001, "personId" => 10, "projectId" => 91_100,
      "roleId" => 7, "startDate" => "2030-05-01", "endDate" => "2030-05-20", "minutesPerDay" => 480, "note" => marker }])
    Stacks::Runn.any_instance.expects(:delete_assignment).never
    delete "/api/v1/resourcing/projected_assignments/arch2:key?archive_runn=true", headers: auth_headers
    assert_response :conflict
    kept = ProjectedAssignment.find_by(source_key: "arch2:key")
    assert kept.present?
    assert_equal 5001, kept.runn_assignment_id # the row is NOT corrupted on conflict
  end

  test "DELETE ?archive_runn=true on a row with no owned assignment is a noop that still deletes the row" do
    ProjectedAssignment.create!(source_key: "arch3:key", project_tracker: @tr, contributor: @contributor,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 0)
    Stacks::Runn.any_instance.expects(:get_assignments).never
    Stacks::Runn.any_instance.expects(:delete_assignment).never
    delete "/api/v1/resourcing/projected_assignments/arch3:key?archive_runn=true", headers: auth_headers
    assert_response :success
    assert_nil ProjectedAssignment.find_by(source_key: "arch3:key")
  end

  test "POST batch applies each item and reports per-item status" do
    Stacks::Runn.any_instance.stubs(:get_assignments).returns(prior_assignment_stub)
    Stacks::Runn.any_instance.stubs(:get_people).returns(people_stub(10))
    Stacks::Runn.any_instance.stubs(:create_assignment).returns({ "id" => 5001 })
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

  test "POST batch fetches the Runn people list only once across items" do
    Stacks::Runn.any_instance.stubs(:get_assignments).returns(prior_assignment_stub)
    Stacks::Runn.any_instance.stubs(:create_assignment).returns({ "id" => 5001 })
    # the whole request shares one WriteThrough, so get_people is fetched once, not per item
    Stacks::Runn.any_instance.expects(:get_people).once.returns(people_stub(10))
    items = [body.merge(source_key: "opt:1"), body.merge(source_key: "opt:2")]
    post "/api/v1/resourcing/projected_assignments/batch",
      headers: auth_headers, params: { items: items }.to_json
    assert_response :success
    assert_equal %w[applied applied], JSON.parse(response.body)["results"].map { |r| r["status"] }
  end

  test "POST batch reports a per-item error when a contributor can't be resolved" do
    Stacks::Runn.any_instance.stubs(:get_assignments).returns(prior_assignment_stub)
    Stacks::Runn.any_instance.stubs(:get_people).returns([])
    Stacks::Runn.any_instance.expects(:create_assignment).never
    items = [body.merge(source_key: "batch:unresolved")]
    post "/api/v1/resourcing/projected_assignments/batch",
      headers: auth_headers, params: { items: items }.to_json
    assert_response :success
    result = JSON.parse(response.body)["results"].first
    assert_equal "error", result["status"]
  end

  test "POST batch marks remaining items deferred when WriteGuard cap is hit" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    store.write("mcp_write_count:#{Time.zone.today.iso8601}", Mcp::WriteGuard::DAILY_CAP)
    Stacks::Runn.any_instance.stubs(:get_assignments).returns(prior_assignment_stub)
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
