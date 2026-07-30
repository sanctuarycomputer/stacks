require "test_helper"

class ProjectedAssignmentTest < ActiveSupport::TestCase
  def contributor_for(email: "c#{SecureRandom.hex(4)}@example.com")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    Contributor.create!(forecast_person: fp)
  end

  def tracker(runn_project_id: rand(1..2_000_000_000))
    RunnProject.find_or_create_by!(runn_id: runn_project_id) { |rp| rp.name = "RP#{runn_project_id}"; rp.data = {} }
    t = ProjectTracker.new(name: "T#{runn_project_id}", runn_project_id: runn_project_id)
    t.save(validate: false)
    t
  end

  def valid_attrs(overrides = {})
    {
      source_key: "resourcing-sweep:extrapolate:#{SecureRandom.hex(4)}",
      contributor: contributor_for,
      project_tracker: tracker,
      start_date: Date.new(2030, 5, 1),
      end_date: Date.new(2030, 5, 31),
      minutes_per_day: 480,
    }.merge(overrides)
  end

  test "valid row saves" do
    assert ProjectedAssignment.new(valid_attrs).valid?
  end

  test "source_key is required and unique" do
    key = "obs:page-1"
    ProjectedAssignment.create!(valid_attrs(source_key: key))
    dup = ProjectedAssignment.new(valid_attrs(source_key: key))
    refute dup.valid?
    assert dup.errors[:source_key].present?
  end

  test "contributor is required" do
    row = ProjectedAssignment.new(valid_attrs(contributor: nil))
    refute row.valid?
    assert row.errors[:contributor].present?
  end

  test "project_tracker is required" do
    row = ProjectedAssignment.new(valid_attrs(project_tracker: nil))
    refute row.valid?
    assert row.errors[:project_tracker].present?
  end

  test "minutes_per_day must be within 0..1440" do
    refute ProjectedAssignment.new(valid_attrs(minutes_per_day: 1441)).valid?
    refute ProjectedAssignment.new(valid_attrs(minutes_per_day: -1)).valid?
    assert ProjectedAssignment.new(valid_attrs(minutes_per_day: 0)).valid?
  end

  test "end_date must be on or after start_date" do
    row = ProjectedAssignment.new(valid_attrs(start_date: Date.new(2030, 5, 10), end_date: Date.new(2030, 5, 1)))
    refute row.valid?
    assert row.errors[:end_date].present?
  end

  test "date range cannot exceed MAX_RANGE_DAYS" do
    row = ProjectedAssignment.new(valid_attrs(start_date: Date.new(2030, 1, 1), end_date: Date.new(2032, 1, 1)))
    refute row.valid?
    assert row.errors[:end_date].present?
  end

  test "note cannot exceed 2000 chars" do
    refute ProjectedAssignment.new(valid_attrs(note: "x" * 2001)).valid?
    assert ProjectedAssignment.new(valid_attrs(note: "x" * 2000)).valid?
  end

  test "runn_assignment_id defaults to nil" do
    row = ProjectedAssignment.create!(valid_attrs)
    assert_nil row.runn_assignment_id
  end

  test "owned scope returns only rows with a runn_assignment_id" do
    bare = ProjectedAssignment.create!(valid_attrs)
    owned = ProjectedAssignment.create!(valid_attrs(runn_assignment_id: 5001))
    assert_includes ProjectedAssignment.owned, owned
    refute_includes ProjectedAssignment.owned, bare
  end

  test "runn_project_id delegates to project_tracker" do
    tr = tracker(runn_project_id: 92_222)
    row = ProjectedAssignment.create!(valid_attrs(project_tracker: tr))
    assert_equal 92_222, row.runn_project_id
  end
end
