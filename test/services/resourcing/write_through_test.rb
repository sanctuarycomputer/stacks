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

  # a live human-authored Runn assignment hash WITHOUT our provenance marker
  def human(id, start_d, end_d, minutes: 480, person: 10, project: 91_100, role: 7)
    { "id" => id, "personId" => person, "projectId" => project, "roleId" => role,
      "startDate" => start_d.iso8601, "endDate" => end_d.iso8601, "minutesPerDay" => minutes, "note" => "hand-authored" }
  end

  test "adopt: takes over a human assignment (delete + recreate owned), before = human snapshot" do
    tr = tracker
    c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31))
    # a NEW row (no runn_assignment_id) that will shorten the human assignment to end 2030-08-31
    w = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, owned_id: nil, key: "obs:roll:1")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([snapshot])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).once.returns({ "id" => 9002 })
    runn.expects(:delete_assignment).once.with(9001).returns({})
    result = service(runn).apply(w, adopt_expected: snapshot)
    assert_equal :applied, result.status
    assert_equal 9002, w.reload.runn_assignment_id
    assert_equal snapshot, result.before   # the pre-adoption human state is the revert material
  end

  test "adopt CAS: human moved the target since the snapshot → conflict, no write" do
    tr = tracker
    c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31))
    moved    = human(9001, Date.new(2030, 1, 1), Date.new(2030, 10, 15)) # human changed the end
    w = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, owned_id: nil, key: "obs:roll:1")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([moved])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    assert_equal :conflict, service(runn).apply(w, adopt_expected: snapshot).status
  end

  test "adopt: target vanished from Runn → conflict, no write" do
    tr = tracker; c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31))
    w = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, owned_id: nil, key: "obs:roll:1")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([]) # gone
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    assert_equal :conflict, service(runn).apply(w, adopt_expected: snapshot).status
  end

  test "adopt refuses a target stacksbot already owns (marked) → conflict, no write" do
    tr = tracker
    c = contributor_for(10)
    # a live assignment that already carries OUR marker (owned by some other row)
    owned = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31)).merge(
      "note" => Resourcing::WriteThrough.provenance_marker("some-other-key"))
    w = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, owned_id: nil, key: "obs:roll:1")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([owned])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    assert_equal :conflict, service(runn).apply(w, adopt_expected: owned).status
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

  test "CAS: live owned no longer equals baseline (human edited it) → relinquished, no Runn write" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 6, 15), contributor: c, owned_id: 5001, baseline: base, key: "wkey")
    runn = mock("runn")
    # human moved the end date in Runn since we last synced → we yield permanently
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 20))])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    result = service(runn).apply(w)
    assert_equal :relinquished, result.status
    assert_equal "relinquished", w.reload.managed_by
  end

  test "CAS: minutes-only drift (human edited it) → relinquished, no Runn write" do
    tr = tracker
    c = contributor_for(10)
    base = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31), minutes: 480)
    w = row(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), minutes: 480, contributor: c,
      owned_id: 5001, baseline: base, key: "wkey")
    runn = mock("runn")
    # human changed only minutesPerDay in Runn since we last synced → we yield
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31), minutes: 240)])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    result = service(runn).apply(w)
    assert_equal :relinquished, result.status
    assert_equal "relinquished", w.reload.managed_by
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

  # --- adopt_into: atomic N-way split of one human assignment ---

  test "adopt_into: splits one human assignment into N owned segments (creates first, deletes once)" do
    tr = tracker
    c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31))
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, key: "seg:1")
    r2 = row(tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([snapshot])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).twice.returns({ "id" => 9101 }, { "id" => 9102 })
    runn.expects(:delete_assignment).once.with(9001).returns({})
    results = service(runn).adopt_into(rows: [r1, r2], adopt_expected: snapshot)
    assert_equal [:applied, :applied], results.map(&:status)
    assert_equal 9101, r1.reload.runn_assignment_id
    assert_equal 9102, r2.reload.runn_assignment_id
    assert r1.last_synced_runn_state.present?
    assert r2.last_synced_runn_state.present?
    assert_equal snapshot, results[0].before
    assert_equal snapshot, results[1].before
  end

  test "adopt_into: group CAS conflict (target moved since snapshot) → all segments conflict, no writes" do
    tr = tracker
    c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31))
    moved    = human(9001, Date.new(2030, 1, 1), Date.new(2030, 10, 15))
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, key: "seg:1")
    r2 = row(tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([moved])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    results = service(runn).adopt_into(rows: [r1, r2], adopt_expected: snapshot)
    assert_equal [:conflict, :conflict], results.map(&:status)
  end

  test "adopt_into: target vanished from Runn → all segments conflict, no writes" do
    tr = tracker
    c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31))
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, key: "seg:1")
    r2 = row(tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    results = service(runn).adopt_into(rows: [r1, r2], adopt_expected: snapshot)
    assert_equal [:conflict, :conflict], results.map(&:status)
  end

  test "adopt_into: target already stacksbot-owned (marked) → all segments conflict, no writes" do
    tr = tracker
    c = contributor_for(10)
    owned = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31)).merge(
      "note" => Resourcing::WriteThrough.provenance_marker("some-other-key"))
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, key: "seg:1")
    r2 = row(tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([owned])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    results = service(runn).adopt_into(rows: [r1, r2], adopt_expected: owned)
    assert_equal [:conflict, :conflict], results.map(&:status)
  end

  test "adopt_into: a segment on a different project than the human → all segments conflict, no writes" do
    tr = tracker
    other_tr = tracker(runn_project_id: 91_200)
    c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31)) # project 91_100
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, key: "seg:1")
    r2 = row(other_tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([snapshot])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    results = service(runn).adopt_into(rows: [r1, r2], adopt_expected: snapshot)
    assert_equal [:conflict, :conflict], results.map(&:status)
  end

  test "adopt_into: create failure rolls back prior creates, leaves the human assignment untouched" do
    tr = tracker
    c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31))
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, key: "seg:1")
    r2 = row(tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([snapshot])
    runn.stubs(:get_people).returns(people_stub(10))
    seq = sequence("adopt_into")
    runn.expects(:create_assignment).in_sequence(seq).returns({ "id" => 9101 })
    runn.expects(:create_assignment).in_sequence(seq).raises(RuntimeError, "runn 500")
    runn.expects(:delete_assignment).with(9101).once.returns({}) # compensating rollback of the first create
    runn.expects(:delete_assignment).with(9001).never             # human never touched
    assert_raises(RuntimeError) { service(runn).adopt_into(rows: [r1, r2], adopt_expected: snapshot) }
    assert_nil r1.reload.runn_assignment_id
    assert_nil r2.reload.runn_assignment_id
  end

  test "adopt_into: final delete failure rolls back ALL creates (total rollback)" do
    tr = tracker
    c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31))
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, key: "seg:1")
    r2 = row(tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([snapshot])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).twice.returns({ "id" => 9101 }, { "id" => 9102 })
    runn.expects(:delete_assignment).with(9001).raises(RuntimeError, "runn 500")
    runn.expects(:delete_assignment).with(9101).once.returns({})
    runn.expects(:delete_assignment).with(9102).once.returns({})
    assert_raises(RuntimeError) { service(runn).adopt_into(rows: [r1, r2], adopt_expected: snapshot) }
    assert_nil r1.reload.runn_assignment_id
    assert_nil r2.reload.runn_assignment_id
  end

  test "adopt_into: an already-owned row re-runs through apply() as a no-op (idempotent re-run)" do
    tr = tracker
    c = contributor_for(10)
    base = live(9101, "seg:1", Date.new(2030, 1, 1), Date.new(2030, 8, 31))
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, owned_id: 9101, baseline: base, key: "seg:1")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([live(9101, "seg:1", Date.new(2030, 1, 1), Date.new(2030, 8, 31))])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    results = service(runn).adopt_into(rows: [r1], adopt_expected: { "id" => 9999 })
    assert_equal [:noop], results.map(&:status)
  end

  test "adopt_into: resolved person differs from the live assignment's personId → all segments conflict, no writes" do
    tr = tracker
    c = contributor_for(11) # resolves to runn person 11 ("Bob")
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31), person: 10) # live assignment belongs to person 10 ("Alice")
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, key: "seg:1")
    r2 = row(tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([snapshot])
    runn.stubs(:get_people).returns(people_stub(11))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    results = service(runn).adopt_into(rows: [r1, r2], adopt_expected: snapshot)
    assert_equal [:conflict, :conflict], results.map(&:status)
  end

  test "adopt_into: mixed contributors across segments → all conflict, no writes" do
    tr = tracker
    c1 = contributor_for(10)
    c2 = contributor_for(11)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31), person: 10)
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c1, key: "seg:1")
    r2 = row(tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c2, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([snapshot])
    runn.stubs(:get_people).returns(people_stub(10)) # resolver only resolves fresh.first's contributor (c1 → person 10)
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    results = service(runn).adopt_into(rows: [r1, r2], adopt_expected: snapshot)
    assert_equal [:conflict, :conflict], results.map(&:status)
  end

  test "adopt_into preview: computes the delta for every segment but writes nothing" do
    tr = tracker
    c = contributor_for(10)
    snapshot = human(9001, Date.new(2030, 1, 1), Date.new(2030, 12, 31))
    r1 = row(tr, Date.new(2030, 1, 1), Date.new(2030, 8, 31), contributor: c, key: "seg:1")
    r2 = row(tr, Date.new(2030, 10, 1), Date.new(2030, 12, 31), contributor: c, key: "seg:2")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([snapshot])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    results = service(runn).adopt_into(rows: [r1, r2], adopt_expected: snapshot, preview: true)
    assert_equal [:preview, :preview], results.map(&:status)
    assert_nil r1.reload.runn_assignment_id
    assert_nil r2.reload.runn_assignment_id
  end
  # --- relinquish: a human hand-edit to an owned assignment yields it permanently ---
  test "apply: human hand-edited our owned assignment → relinquished, no write, row marked" do
    tr = tracker
    c = contributor_for(10)
    key = "obs:owned:1"
    baseline = live(555, key, Date.new(2030, 1, 1), Date.new(2030, 6, 30)) # what we last wrote
    w = row(tr, Date.new(2030, 1, 1), Date.new(2030, 6, 30), contributor: c, owned_id: 555, baseline: baseline, key: key)
    edited = live(555, key, Date.new(2030, 1, 1), Date.new(2030, 9, 30)) # human moved the end date; marker + id intact
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([edited])
    runn.stubs(:get_people).returns(people_stub(10))
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    result = service(runn).apply(w)
    assert_equal :relinquished, result.status
    assert_equal edited, result.before
    assert_equal "relinquished", w.reload.managed_by
  end

  test "apply: a relinquished row is never touched again (noop, no Runn calls at all)" do
    tr = tracker
    c = contributor_for(11)
    w = ProjectedAssignment.create!(source_key: "obs:relinq:1", project_tracker: tr, contributor: c,
      start_date: Date.new(2030, 1, 1), end_date: Date.new(2030, 6, 30), minutes_per_day: 480,
      runn_assignment_id: 556, last_synced_runn_state: live(556, "obs:relinq:1", Date.new(2030, 1, 1), Date.new(2030, 6, 30)),
      managed_by: "relinquished")
    runn = mock("runn")
    runn.expects(:get_assignments).never
    runn.expects(:get_people).never
    assert_equal :noop, service(runn).apply(w).status
  end

  test "apply preview: relinquish is detected but NOT persisted" do
    tr = tracker
    c = contributor_for(12)
    key = "obs:owned:2"
    baseline = live(557, key, Date.new(2030, 1, 1), Date.new(2030, 6, 30))
    w = row(tr, Date.new(2030, 1, 1), Date.new(2030, 6, 30), contributor: c, owned_id: 557, baseline: baseline, key: key)
    edited = live(557, key, Date.new(2030, 1, 1), Date.new(2030, 9, 30))
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([edited])
    runn.stubs(:get_people).returns(people_stub(12))
    assert_equal :relinquished, service(runn).apply(w, preview: true).status
    assert_nil w.reload.managed_by, "preview must not persist the yield"
  end

  test "archive: a relinquished row is never touched (noop)" do
    tr = tracker
    c = contributor_for(13)
    w = ProjectedAssignment.create!(source_key: "obs:relinq:2", project_tracker: tr, contributor: c,
      start_date: Date.new(2030, 1, 1), end_date: Date.new(2030, 6, 30), minutes_per_day: 480,
      runn_assignment_id: 558, last_synced_runn_state: live(558, "obs:relinq:2", Date.new(2030, 1, 1), Date.new(2030, 6, 30)),
      managed_by: "relinquished")
    runn = mock("runn")
    runn.expects(:get_assignments).never
    runn.expects(:delete_assignment).never
    assert_equal :noop, service(runn).archive(w).status
  end

end
