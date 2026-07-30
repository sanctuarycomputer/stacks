require "test_helper"

class ProjectedAssignmentTest < ActiveSupport::TestCase
  def contributor_for(email: "c#{SecureRandom.hex(4)}@example.com")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    Contributor.create!(forecast_person: fp)
  end

  def valid_attrs(overrides = {})
    {
      source_key: "resourcing-sweep:extrapolate:#{SecureRandom.hex(4)}",
      contributor: contributor_for,
      runn_role_id: 7,
      start_date: Date.new(2030, 5, 1),
      end_date: Date.new(2030, 5, 31),
      minutes_per_day: 480,
      kind: "work",
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

  test "kind must be in KINDS" do
    row = ProjectedAssignment.new(valid_attrs(kind: "vacation"))
    refute row.valid?
    assert row.errors[:kind].present?
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

  test "runn_assignment_ids defaults to an empty array and owned_runn_assignment_ids returns it" do
    row = ProjectedAssignment.create!(valid_attrs)
    assert_equal [], row.runn_assignment_ids
    assert_equal [], row.owned_runn_assignment_ids
  end

  test "owned scope returns only rows with runn_assignment_ids" do
    bare = ProjectedAssignment.create!(valid_attrs)
    owned = ProjectedAssignment.create!(valid_attrs(runn_assignment_ids: [5001]))
    assert_includes ProjectedAssignment.owned, owned
    refute_includes ProjectedAssignment.owned, bare
  end

  test "for_contributor and time_off scopes filter" do
    shared = contributor_for
    a = ProjectedAssignment.create!(valid_attrs(contributor: shared, kind: "work"))
    b = ProjectedAssignment.create!(valid_attrs(contributor: shared, kind: "time_off", minutes_per_day: 0))
    c = ProjectedAssignment.create!(valid_attrs(kind: "work"))
    assert_equal [a, b].sort_by(&:id), ProjectedAssignment.for_contributor(shared.id).order(:id).to_a
    assert_equal [b], ProjectedAssignment.time_off.to_a
    assert_not_includes ProjectedAssignment.for_contributor(shared.id), c
  end
end
