require "test_helper"

class Resourcing::WriteThroughTest < ActiveSupport::TestCase
  def tracker(runn_project_id: 91_100)
    RunnProject.find_or_create_by!(runn_id: runn_project_id) { |rp| rp.name = "RP#{runn_project_id}"; rp.data = {} }
    t = ProjectTracker.new(name: "T#{runn_project_id}", runn_project_id: runn_project_id)
    t.save(validate: false)
    t
  end

  def work(tr, start_d, end_d, minutes: 480, person: 10, role: 7, owned: [], baseline: nil, key: "w#{SecureRandom.hex(3)}")
    ProjectedAssignment.create!(source_key: key, project_tracker: tr, runn_person_id: person, runn_role_id: role,
      start_date: start_d, end_date: end_d, minutes_per_day: minutes, kind: "work",
      runn_assignment_ids: owned, last_synced_runn_state: baseline)
  end

  # a live Runn assignment hash carrying our provenance marker
  def live(id, key, start_d, end_d, minutes: 480, person: 10, project: 91_100, role: 7)
    { "id" => id, "personId" => person, "projectId" => project, "roleId" => role,
      "startDate" => start_d.iso8601, "endDate" => end_d.iso8601, "minutesPerDay" => minutes,
      "note" => Resourcing::WriteThrough.provenance_marker(key) }
  end

  def service(runn)
    s = Resourcing::WriteThrough.new
    s.runn = runn
    s
  end

  test "create: a brand-new work row creates one Runn assignment and records ownership" do
    tr = tracker
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([])
    runn.stubs(:get_leave_for_person).returns([])
    runn.expects(:create_assignment).once.returns([{ "id" => 5001 }])
    result = service(runn).apply(w)
    assert_equal :applied, result.status
    assert_equal [5001], w.reload.runn_assignment_ids
    assert w.reload.last_synced_runn_state.present?
  end

  test "noop: desired equals live owned → no Runn writes" do
    tr = tracker
    base = [live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))]
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), owned: [5001], baseline: base, key: "wkey")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))])
    runn.stubs(:get_leave_for_person).returns([])
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    assert_equal :noop, service(runn).apply(w).status
  end

  test "align: changing the end date deletes the old assignment and creates the new one" do
    tr = tracker
    base = [live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))]
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 6, 15), owned: [5001], baseline: base, key: "wkey")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))])
    runn.stubs(:get_leave_for_person).returns([])
    runn.expects(:create_assignment).once.returns([{ "id" => 5002 }])
    runn.expects(:delete_assignment).once.with(5001).returns({})
    result = service(runn).apply(w)
    assert_equal :applied, result.status
    assert_equal [5002], w.reload.runn_assignment_ids
  end

  test "CAS conflict: live owned no longer equals baseline → 409, no Runn write" do
    tr = tracker
    base = [live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))]
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 6, 15), owned: [5001], baseline: base, key: "wkey")
    runn = mock("runn")
    # human moved the end date in Runn since we last synced
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 20))])
    runn.stubs(:get_leave_for_person).returns([])
    runn.expects(:create_assignment).never
    runn.expects(:delete_assignment).never
    result = service(runn).apply(w)
    assert_equal :conflict, result.status
    assert result.conflict.present?
  end

  test "provenance conflict: a claimed-owned assignment lost our marker → 409, no write" do
    tr = tracker
    base = [live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))]
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 6, 15), owned: [5001], baseline: base, key: "wkey")
    hijacked = live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31)).merge("note" => "hand-edited by a human")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([hijacked])
    runn.stubs(:get_leave_for_person).returns([])
    runn.expects(:create_assignment).never
    assert_equal :conflict, service(runn).apply(w).status
  end

  test "compensating rollback: a delete failure after a create removes the created assignment" do
    tr = tracker
    base = [live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))]
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 6, 15), owned: [5001], baseline: base, key: "wkey")
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([live(5001, "wkey", Date.new(2030, 5, 1), Date.new(2030, 5, 31))])
    runn.stubs(:get_leave_for_person).returns([])
    runn.expects(:create_assignment).once.returns([{ "id" => 5002 }])
    seq = sequence("apply")
    runn.expects(:delete_assignment).with(5001).in_sequence(seq).raises(RuntimeError, "runn 500")
    runn.expects(:delete_assignment).with(5002).in_sequence(seq).returns({}) # rollback of the created row
    assert_raises(RuntimeError) { service(runn).apply(w) }
    assert_equal [5001], w.reload.runn_assignment_ids # unchanged — world restored
  end

  test "preview: computes the delta but writes nothing" do
    tr = tracker
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    runn = mock("runn")
    runn.stubs(:get_assignments).returns([])
    runn.stubs(:get_leave_for_person).returns([])
    runn.expects(:create_assignment).never
    result = service(runn).apply(w, preview: true)
    assert_equal :preview, result.status
    assert_equal 1, result.after.size
  end
end
