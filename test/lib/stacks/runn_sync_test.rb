require "test_helper"

# Covers the local mirror of Runn people / roles / assignments. Reads are
# stubbed on the instance; nothing here touches HTTP.
class Stacks::RunnSyncTest < ActiveSupport::TestCase
  def runn
    r = Stacks::Runn.allocate # skip initialize (needs Runn API config)
    r.instance_variable_set(:@max_retries, 0)
    r.instance_variable_set(:@headers, {})
    r
  end

  def person(id, updated_at: "2026-09-01T00:00:00.000Z", email: "p#{id}@example.com", archived: false)
    { "id" => id, "firstName" => "F#{id}", "lastName" => "L#{id}", "email" => email, "isArchived" => archived,
      "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => updated_at }
  end

  def role(id, updated_at: "2026-09-01T00:00:00.000Z", rate: 195)
    { "id" => id, "name" => "$#{rate}.00 p/h", "standardRate" => rate, "defaultHourCost" => 0, "isArchived" => false,
      "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => updated_at }
  end

  def assignment(id, updated_at: "2026-09-01T00:00:00.000Z", minutes: 480)
    { "id" => id, "personId" => 1, "projectId" => 10, "roleId" => 100, "startDate" => "2026-09-07", "endDate" => "2026-09-11",
      "minutesPerDay" => minutes, "isActive" => true, "note" => "", "isBillable" => true, "phaseId" => nil,
      "isNonWorkingDay" => false, "isTemplate" => false, "isPlaceholder" => false, "workstreamId" => nil,
      "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => updated_at }
  end

  def project(id, updated_at: "2026-09-01T00:00:00.000Z")
    { "id" => id, "name" => "Proj #{id}", "isTemplate" => false, "isArchived" => false, "isConfirmed" => true,
      "pricingModel" => "tm", "rateType" => "role", "budget" => 0, "expensesBudget" => 0,
      "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => updated_at }
  end

  def stub_reads(r, people: [], roles: [], assignments: [], projects: [])
    r.stubs(:get_people).returns(people)
    r.stubs(:get_roles).returns(roles)
    r.stubs(:get_assignments).returns(assignments)
    r.stubs(:get_projects).returns(projects)
    r
  end

  test "sync_people! maps columns, keeps the raw payload, and returns seen ids" do
    ids = runn.sync_people!([person(1, email: "One@Example.com"), person(2, archived: true)])
    assert_equal [1, 2], ids
    p1 = RunnPerson.find(1)
    assert_equal "F1", p1.first_name
    assert_equal "One@Example.com", p1.email
    assert_equal false, p1.is_archived
    assert_equal "One@Example.com", p1.data["email"]
    assert RunnPerson.find(2).is_archived
  end

  test "sync_roles! maps standard_rate and default_hour_cost" do
    runn.sync_roles!([role(100, rate: 225)])
    r = RunnRole.find(100)
    assert_equal 225, r.standard_rate
    assert_equal 0, r.default_hour_cost
    assert_equal "$225.00 p/h", r.name
  end

  test "sync_assignments! maps every column" do
    runn.sync_assignments!([assignment(5000)])
    a = RunnAssignment.find(5000)
    assert_equal 1, a.person_id
    assert_equal 10, a.project_id
    assert_equal 100, a.role_id
    assert_equal Date.new(2026, 9, 7), a.start_date
    assert_equal Date.new(2026, 9, 11), a.end_date
    assert_equal 480, a.minutes_per_day
    assert a.is_active && a.is_billable
    assert_not a.is_placeholder
    assert_not a.is_template
    assert_not a.is_non_working_day
    assert_equal Time.parse("2026-09-01T00:00:00.000Z").to_i, a.updated_at.to_i
  end

  test "sync_projects! reads updatedAt (not UpdatedAt) so the column is populated" do
    runn.sync_projects!([project(10, updated_at: "2026-09-02T00:00:00.000Z")])
    assert_equal Time.parse("2026-09-02T00:00:00.000Z").to_i, RunnProject.find(10).updated_at.to_i
  end

  test "upsert_changed! skips rows whose updated_at did not move but still reports them seen" do
    r = runn
    r.sync_assignments!([assignment(5001), assignment(5002)])
    RunnAssignment.expects(:upsert_all).never
    ids = r.sync_assignments!([assignment(5001), assignment(5002)])
    assert_equal [5001, 5002], ids
  end

  test "upsert_changed! rewrites only rows whose updated_at advanced, plus new rows" do
    r = runn
    r.sync_assignments!([assignment(5003, minutes: 480), assignment(5004, minutes: 480)])
    captured = nil
    RunnAssignment.stubs(:upsert_all).with { |rows, **| captured = rows.map { |x| x[:runn_id] }; true }
    ids = r.sync_assignments!([
      assignment(5003, minutes: 480),
      assignment(5004, updated_at: "2026-09-05T00:00:00.000Z", minutes: 240),
      assignment(5005),
    ])
    assert_equal [5004, 5005], captured
    assert_equal [5003, 5004, 5005], ids
  end

  test "a changed assignment's new values land" do
    r = runn
    r.sync_assignments!([assignment(5006, minutes: 480)])
    r.sync_assignments!([assignment(5006, updated_at: "2026-09-05T00:00:00.000Z", minutes: 60)])
    assert_equal 60, RunnAssignment.find(5006).minutes_per_day
  end

  test "prune_assignments_not_in! deletes unseen assignments and is a no-op on blank input" do
    r = runn
    r.sync_assignments!([assignment(5007), assignment(5008)])
    r.prune_assignments_not_in!([])
    assert_equal 2, RunnAssignment.where(runn_id: [5007, 5008]).count
    r.prune_assignments_not_in!([5007])
    assert_equal [5007], RunnAssignment.where(runn_id: [5007, 5008]).pluck(:runn_id)
  end

  test "sync_all! runs every sync, prunes, and stamps runn_synced_at only on full success" do
    System.first || System.create!(settings: {})
    System.first.update!(runn_synced_at: nil)
    r = stub_reads(runn, people: [person(1)], roles: [role(100)], assignments: [assignment(5009)], projects: [project(10)])
    RunnAssignment.create!(runn_id: 5010, person_id: 1, project_id: 10, role_id: 100, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 2), minutes_per_day: 60)

    r.sync_all!

    assert RunnPerson.exists?(1)
    assert RunnRole.exists?(100)
    assert RunnProject.exists?(10)
    assert RunnAssignment.exists?(5009)
    assert_not RunnAssignment.exists?(5010), "unseen assignment pruned"
    assert_not_nil System.first.runn_synced_at
  end

  test "sync_all! leaves runn_synced_at untouched and earlier tables written when a later sync raises" do
    System.first || System.create!(settings: {})
    System.first.update!(runn_synced_at: nil)
    r = stub_reads(runn, people: [person(3)], roles: [role(101)], projects: [project(11)])
    r.stubs(:get_assignments).raises(RuntimeError, "boom")

    assert_raises(RuntimeError) { r.sync_all! }
    assert RunnProject.exists?(11)
    assert RunnPerson.exists?(3)
    assert RunnRole.exists?(101)
    assert_nil System.first.runn_synced_at
  end

  test "sync_all! never deletes people or roles" do
    r = stub_reads(runn, people: [person(4)], roles: [role(102)], assignments: [], projects: [])
    r.sync_all!
    r2 = stub_reads(runn, people: [], roles: [], assignments: [], projects: [])
    r2.sync_all!
    assert RunnPerson.exists?(4)
    assert RunnRole.exists?(102)
  end

  test "sync_all! skips when the advisory lock is held" do
    r = stub_reads(runn)
    ActiveRecord::Base.connection.stubs(:select_value).with("SELECT pg_try_advisory_lock(#{Stacks::Runn::SYNC_ALL_ADVISORY_LOCK_KEY})").returns(false)
    r.expects(:sync_projects!).never
    r.sync_all!
  end
end
