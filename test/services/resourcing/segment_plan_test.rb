require "test_helper"

class Resourcing::SegmentPlanTest < ActiveSupport::TestCase
  def tracker(runn_project_id: 91_100)
    RunnProject.find_or_create_by!(runn_id: runn_project_id) { |rp| rp.name = "RP#{runn_project_id}"; rp.data = {} }
    t = ProjectTracker.new(name: "T#{runn_project_id}", runn_project_id: runn_project_id)
    t.save(validate: false)
    t
  end

  def work(tr, start_d, end_d, minutes: 480, person: 10, role: 7, key: "w#{SecureRandom.hex(3)}")
    ProjectedAssignment.create!(source_key: key, project_tracker: tr, runn_person_id: person,
      runn_role_id: role, start_date: start_d, end_date: end_d, minutes_per_day: minutes, kind: "work")
  end

  def modifier(kind, tr, start_d, end_d, person: 10, capacity_pct: nil, key: "m#{SecureRandom.hex(3)}")
    ProjectedAssignment.create!(source_key: key, project_tracker: tr, runn_person_id: person,
      start_date: start_d, end_date: end_d, minutes_per_day: 0, kind: kind, capacity_pct: capacity_pct)
  end

  test "create: a lone work row yields one full segment" do
    tr = tracker
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    segs = Resourcing::SegmentPlan.new(work_rows: [w], modifier_rows: []).desired_segments
    assert_equal 1, segs.size
    assert_equal [Date.new(2030, 5, 1), Date.new(2030, 5, 31), 480, 91_100, 10, 7],
      [segs[0].start_date, segs[0].end_date, segs[0].minutes_per_day, segs[0].runn_project_id, segs[0].runn_person_id, segs[0].runn_role_id]
  end

  test "time_off split: a mid-window time_off carves the work row into two segments" do
    tr = tracker
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    t = modifier("time_off", tr, Date.new(2030, 5, 10), Date.new(2030, 5, 15))
    segs = Resourcing::SegmentPlan.new(work_rows: [w], modifier_rows: [t]).desired_segments.sort_by(&:start_date)
    assert_equal 2, segs.size
    assert_equal [Date.new(2030, 5, 1), Date.new(2030, 5, 9)], [segs[0].start_date, segs[0].end_date]
    assert_equal [Date.new(2030, 5, 16), Date.new(2030, 5, 31)], [segs[1].start_date, segs[1].end_date]
  end

  test "time_off noop when Runn native leave already covers the window" do
    tr = tracker
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    t = modifier("time_off", tr, Date.new(2030, 5, 10), Date.new(2030, 5, 15))
    leave = [{ "startDate" => "2030-05-09", "endDate" => "2030-05-16" }]
    segs = Resourcing::SegmentPlan.new(work_rows: [w], modifier_rows: [t], native_leave: leave).desired_segments
    assert_equal 1, segs.size
    assert_equal [Date.new(2030, 5, 1), Date.new(2030, 5, 31)], [segs[0].start_date, segs[0].end_date]
  end

  test "reduced scale: a reduced modifier scales minutes over its window into three pieces" do
    tr = tracker
    w = work(tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31), minutes: 480)
    r = modifier("reduced", tr, Date.new(2030, 5, 10), Date.new(2030, 5, 20), capacity_pct: 50)
    segs = Resourcing::SegmentPlan.new(work_rows: [w], modifier_rows: [r]).desired_segments.sort_by(&:start_date)
    assert_equal 3, segs.size
    assert_equal [480, 240, 480], segs.map(&:minutes_per_day)
    assert_equal [Date.new(2030, 5, 10), Date.new(2030, 5, 20)], [segs[1].start_date, segs[1].end_date]
  end

  test "archive: a work row fully covered by time_off yields no segments" do
    tr = tracker
    w = work(tr, Date.new(2030, 5, 10), Date.new(2030, 5, 15))
    t = modifier("time_off", tr, Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    segs = Resourcing::SegmentPlan.new(work_rows: [w], modifier_rows: [t]).desired_segments
    assert_empty segs
  end

  test "org-wide modifier (nil tracker) applies across a different project's work row" do
    tr_a = tracker(runn_project_id: 91_100)
    w = work(tr_a, Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    org_wide = ProjectedAssignment.create!(source_key: "obs:org1", project_tracker: nil, runn_person_id: 10,
      start_date: Date.new(2030, 5, 10), end_date: Date.new(2030, 5, 15), minutes_per_day: 0, kind: "time_off")
    segs = Resourcing::SegmentPlan.new(work_rows: [w], modifier_rows: [org_wide]).desired_segments
    assert_equal 2, segs.size
  end

  test "a modifier scoped to a different tracker does not affect the work row" do
    tr_a = tracker(runn_project_id: 91_100)
    tr_b = tracker(runn_project_id: 92_200)
    w = work(tr_a, Date.new(2030, 5, 1), Date.new(2030, 5, 31))
    t = modifier("time_off", tr_b, Date.new(2030, 5, 10), Date.new(2030, 5, 15))
    segs = Resourcing::SegmentPlan.new(work_rows: [w], modifier_rows: [t]).desired_segments
    assert_equal 1, segs.size
  end
end
