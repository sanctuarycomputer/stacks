require "test_helper"

class Resourcing::WriteThroughTest < ActiveSupport::TestCase
  def contributor_for(runn_id, email: "c#{runn_id}@example.com")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    Contributor.create!(forecast_person: fp)
  end

  def people_stub(runn_id, email: "c#{runn_id}@example.com")
    [{ "id" => runn_id, "email" => email, "isArchived" => false }]
  end

  def tracker(runn_project_id: 91_100)
    RunnProject.find_or_create_by!(runn_id: runn_project_id) { |rp| rp.name = "RP#{runn_project_id}"; rp.data = {} }
    t = ProjectTracker.new(name: "T#{runn_project_id}", runn_project_id: runn_project_id)
    t.save(validate: false)
    t
  end

  def row(tr, start_d, end_d, minutes: 480, contributor:, owned_id: nil, baseline: nil, key: "w#{SecureRandom.hex(3)}")
    ProjectedAssignment.create!(source_key: key, project_tracker: tr, contributor: contributor,
      start_date: start_d, end_date: end_d, minutes_per_day: minutes,
      runn_assignment_id: owned_id, last_synced_runn_state: baseline)
  end

  # a live Runn assignment hash carrying our provenance marker
  def live(id, key, start_d, end_d, minutes: 480, person: 10, project: 91_100, role: 7)
    { "id" => id, "personId" => person, "projectId" => project, "roleId" => role,
      "startDate" => start_d.iso8601, "endDate" => end_d.iso8601, "minutesPerDay" => minutes,
      "note" => Resourcing::WriteThrough.provenance_marker(key) }
  end

  def service(runn)
    Resourcing::WriteThrough.new(runn: runn)
  end

  test "create: a brand-new row with a prior role for the person creates one Runn assignment and records ownership" do
    tr = tracker
    c = contributor_for(10)
    prior = live(4000, "priorkey", Date.new(2029, 1, 1), Date.new(2029, 1, 31), role: 9)
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), contributor: c)
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([prior])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).once.with(
      person_id: 10, project_id: 91_100, role_id: 9,
      start_date: "2030-05-01", end_date: "2030-05-31", minutes_per_day: 480,
      note: Resourcing::WriteThrough.provenance_marker(w.source_key)
    ).returns({ "id" => 5001 })
    result = service(runn).apply(w)
    assert_equal :applied, result.status
    assert_equal 5001, w.reload.runn_assignment_id
    assert w.reload.last_synced_runn_state.present?
  end

  test "role: no prior assignment for the person raises UnresolvableRole; no writes" do
    tr = tracker
    c = contributor_for(10)
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), contributor: c)
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    assert_raises(Resourcing::WriteThrough::UnresolvableRole) { service(runn).apply(w) }
    assert_nil w.reload.runn_assignment_id
  end

  test "noop: desired equals live owned → no Runn writes" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), contributor: c, owned_id: 5001, baseline: base, key: "wkey")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    assert_equal :noop, service(runn).apply(w).status
  end

  test "shorten/replace: changing the end date creates the new assignment then deletes the old" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 6, 15), contributor: c, owned_id: 5001, baseline: base, key: "wkey")
    runn = mock("runn")
    # A second, LATER assignment with a different role (9) so the fallback
    # (most_recent_role_id) would pick 9 — the matcher below only passes if the
    # code reuses the CURRENT owned assignment's role (7), genuinely guarding the
    # reuse branch against regressing to the fallback.
    runn.stubs(:get_assignments).returns([
      live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31)),
      live(5099, "other", Date.new(2030, 6, 1), Date.new(2030, 6, 30), role: 9),
    ])
    runn.stubs(:get_people).returns(people_stub(10))
    seq = sequence("apply")
    # the reused role (7, from the current owned assignment) must reach Runn unchanged —
    # a regression here would silently re-role an existing assignment on every edit.
    runn.expects(:create_assignment).in_sequence(seq).with { |kw| kw[:role_id] == 7 }.returns({ "id" => 5002 })
    runn.expects(:delete_assignment).once.in_sequence(seq).with(5001).returns({})
    result = service(runn).apply(w)
    assert_equal :applied, result.status
    assert_equal 5002, w.reload.runn_assignment_id
  end

  test "CAS conflict: live owned no longer equals baseline → conflict, no Runn write" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 6, 15), contributor: c, owned_id: 5001, baseline: base, key: "wkey")
    runn = mock("runn")
    # human moved the end date in Runn since we last synced
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 20))])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    result = service(runn).apply(w)
    assert_equal :conflict, result.status
    assert result.conflict.present?
  end

  test "CAS conflict: minutes-only drift (same person/project/role/dates) → conflict, no Runn write" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31), minutes: 480)
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), minutes: 480, contributor: c,
      owned_id: 5001, baseline: base, key: "wkey")
    runn = mock("runn")
    # human changed only minutesPerDay in Runn since we last synced
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31), minutes: 240)])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    result = service(runn).apply(w)
    assert_equal :conflict, result.status
    assert result.conflict.present?
  end

  test "provenance conflict: a claimed-owned assignment lost our marker → conflict, no write" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 6, 15), contributor: c, owned_id: 5001, baseline: base, key: "wkey")
    hijacked = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31)).merge("note" => "hand-edited by a human")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([hijacked])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    assert_equal :conflict, service(runn).apply(w).status
  end

  test "compensating rollback: a delete failure after a create removes the created assignment" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 6, 15), contributor: c, owned_id: 5001, baseline: base, key: "wkey")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).once.returns({ "id" => 5002 })
    seq = sequence("apply")
    runn.expects(:delete_assignment).with(5001).in_sequence(seq).raises(RuntimeError, "runn 500")
    runn.expects(:delete_assignment).with(5002).in_sequence(seq).returns({}) # rollback of the created row
    assert_raises(RuntimeError) { service(runn).apply(w) }
    assert_equal 5001, w.reload.runn_assignment_id # unchanged — world restored
  end

  test "preview: computes the delta but writes nothing" do
    tr = tracker
    c = contributor_for(10)
    prior = live(4000, "priorkey", Date.new(2029, 1, 1), Date.new(2029, 1, 31), role: 9)
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), contributor: c)
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([prior])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    result = service(runn).apply(w, preview: true)
    assert_equal :preview, result.status
    assert_nil w.reload.runn_assignment_id
  end

  test "unresolved contributor: email matches 0 active Runn people raises UnresolvedContributor" do
    tr = tracker
    c = contributor_for(10, email: "nomatch@example.com")
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), contributor: c)
    runn = mock("runn")
    runn.stubs(:get_people).returns(people_stub(10, email: "someoneelse@example.com"))
    runn.expects(:get_assignments).never
    runn.expects(:create_assignment).never
    assert_raises(Resourcing::WriteThrough::UnresolvedContributor) { service(runn).apply(w) }
  end

  test "unresolved contributor: email matches >1 active Runn people raises UnresolvedContributor" do
    tr = tracker
    c = contributor_for(10, email: "shared@example.com")
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), contributor: c)
    runn = mock("runn")
    runn.stubs(:get_people).returns([
      { "id" => 10, "email" => "shared@example.com", "isArchived" => false },
      { "id" => 11, "email" => "shared@example.com", "isArchived" => false },
    ])
    runn.expects(:create_assignment).never
    assert_raises(Resourcing::WriteThrough::UnresolvedContributor) { service(runn).apply(w) }
  end

  test "archive: deletes the owned assignment when live still matches" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), contributor: c, owned_id: 5001, baseline: base, key: "wkey")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))])
    runn.expects(:delete_assignment).once.with(5001).returns({})
    assert_equal :applied, service(runn).archive(w).status
  end

  test "archive: a human edit blocks deletion (conflict); assignment untouched" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), contributor: c, owned_id: 5001, baseline: base, key: "wkey")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 20))])
    runn.expects(:delete_assignment).never
    result = service(runn).archive(w)
    assert_equal :conflict, result.status
    assert_equal 5001, w.reload.runn_assignment_id
  end

  test "archive: no owned assignment is a noop" do
    tr = tracker
    c = contributor_for(10)
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), contributor: c, key: "wkey")
    runn = mock("runn")
    runn.expects(:get_assignments).never
    runn.expects(:delete_assignment).never
    assert_equal :noop, service(runn).archive(w).status
  end
end
