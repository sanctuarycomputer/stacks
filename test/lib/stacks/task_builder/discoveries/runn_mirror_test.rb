require "test_helper"

class Stacks::TaskBuilder::Discoveries::RunnMirrorTest < ActiveSupport::TestCase
  setup do
    @admin = AdminUser.create!(email: "rmadmin#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
    @seq = 700_000 + rand(100_000)
    (System.first || System.create!(settings: {})).update!(runn_synced_at: Time.current)
  end

  def nid
    @seq += 1
  end

  def discover
    Stacks::TaskBuilder::Discoveries::RunnMirror.new(admin_fallback: [@admin]).tasks
  end

  def runn_project!(name: "RP #{@seq}", archived: false, managers: [])
    RunnProject.create!(runn_id: nid, name: name, is_confirmed: true, is_archived: archived, is_template: false,
                        data: { "managerIds" => managers })
  end

  def runn_person!(email, archived: false)
    RunnPerson.create!(runn_id: nid, first_name: "Runn", last_name: "Person", email: email, is_archived: archived)
  end

  def runn_role!(rate)
    RunnRole.create!(runn_id: nid, name: "$#{rate}.00 p/h", standard_rate: rate, default_hour_cost: 0)
  end

  def assign!(person, project, role, from: Date.today + 3, to: Date.today + 10, placeholder: false)
    RunnAssignment.create!(runn_id: nid, person_id: person.runn_id, project_id: project.runn_id, role_id: role.runn_id,
                           start_date: from, end_date: to, minutes_per_day: 480, is_placeholder: placeholder)
  end

  def forecast_person!(email)
    ForecastPerson.create!(forecast_id: nid, email: email, data: {})
  end

  def tracker!(runn_project, rate: 200, lead: nil)
    client = ForecastClient.create!(forecast_id: nid, name: "Client #{@seq}")
    ws = ForecastProject.create!(forecast_id: nid, client_id: client.forecast_id, name: "WS #{@seq}", code: "WS-#{@seq}", tags: ["#{rate}p/h"])
    pt = ProjectTracker.new(name: "Tracker #{@seq}", runn_project_id: runn_project.runn_id)
    pt.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: ws)
    ProjectLeadPeriod.create!(project_tracker: pt, admin_user: lead, started_at: Date.today.beginning_of_month) if lead
    pt
  end

  # --- unlinked projects ---------------------------------------------------

  test "a live Runn project with forward hours and no tracker is a task for the admin team" do
    rp = runn_project!(name: "Orphan")
    assign!(runn_person!("p#{@seq}@example.com"), rp, runn_role!(200))
    t = discover.find { |x| x.subject == rp }
    assert_equal :runn_project_not_linked_to_project_tracker, t.type
    assert_equal [@admin], t.owners
    assert_equal "Orphan", t.subject_display_name
    assert_includes t.subject_url, "project_tracker%5Brunn_project_id%5D=#{rp.runn_id}"
    assert_not t.subject_url_external?
  end

  test "an unlinked project's Runn managers own the task when they are admin users" do
    manager_admin = AdminUser.create!(email: "mgr#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123")
    manager = runn_person!(manager_admin.email.upcase)
    rp = runn_project!(managers: [manager.runn_id])
    assign!(runn_person!("p#{@seq}@example.com"), rp, runn_role!(200))
    assert_equal [manager_admin], discover.find { |x| x.subject == rp }.owners
  end

  test "linked, archived, and past-only Runn projects are not tasks" do
    linked = runn_project!
    tracker!(linked)
    assign!(runn_person!("a#{@seq}@example.com"), linked, runn_role!(200))
    archived = runn_project!(archived: true)
    assign!(runn_person!("b#{@seq}@example.com"), archived, runn_role!(200))
    past = runn_project!
    assign!(runn_person!("c#{@seq}@example.com"), past, runn_role!(200), from: Date.today - 20, to: Date.today - 10)

    subjects = discover.map(&:subject)
    assert_not_includes subjects, linked
    assert_not_includes subjects, archived
    assert_not_includes subjects, past
  end

  # --- unmatched people ----------------------------------------------------

  test "a Runn person with forward hours and no Forecast person is a task; a matched one is not" do
    rp = runn_project!
    tracker!(rp)
    role = runn_role!(200)
    stranger = runn_person!("stranger#{@seq}@example.com")
    assign!(stranger, rp, role)
    known = runn_person!("Known#{@seq}@Example.com")
    forecast_person!(known.email.downcase)
    assign!(known, rp, role)

    tasks = discover
    t = tasks.find { |x| x.subject == stranger }
    assert_equal :runn_person_not_in_forecast, t.type
    assert_equal [@admin], t.owners
    assert_equal "Runn Person", t.subject_display_name
    assert_equal stranger.link, t.subject_url
    assert t.subject_url_external?
    assert_nil tasks.find { |x| x.subject == known }
  end

  test "placeholder assignments never produce a task of any kind" do
    seat = runn_person!("")
    role = runn_role!(999)
    unlinked = runn_project!(name: "Seats only")
    assign!(seat, unlinked, role, placeholder: true)
    mismatched_pt = tracker!(runn_project!, rate: 200)
    assign!(seat, RunnProject.find(mismatched_pt.runn_project_id), role, placeholder: true)

    subjects = discover.map(&:subject)
    assert_not_includes subjects, seat
    assert_not_includes subjects, unlinked
    assert_not_includes subjects, mismatched_pt
  end

  test "assignments outside the projection horizon do not raise tasks" do
    horizon_end = ContributorProjections::Horizon.current.ends_at
    later = runn_project!(name: "Next year")
    assign!(runn_person!("later#{@seq}@example.com"), later, runn_role!(200), from: horizon_end + 1, to: horizon_end + 5)
    assert_nil discover.find { |x| x.subject == later }
  end

  test "a non-billable assignment does not raise a rate-mismatch task" do
    rp = runn_project!
    pt = tracker!(rp, rate: 200)
    person = runn_person!("nb#{@seq}@example.com")
    a = assign!(person, rp, runn_role!(999))
    a.update!(is_billable: false)
    assert_nil discover.find { |x| x.subject == pt }
  end

  # --- rate mismatches -----------------------------------------------------

  test "a forward assignment whose role rate matches no workstream is a task for the project leads" do
    lead = AdminUser.create!(email: "lead#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123")
    rp = runn_project!
    pt = tracker!(rp, rate: 200, lead: lead)
    assign!(runn_person!("m#{@seq}@example.com"), rp, runn_role!(999))
    t = discover.find { |x| x.subject == pt }
    assert_equal :runn_role_rate_mismatch, t.type
    assert_equal [lead], t.owners
  end

  test "a matching role rate produces no mismatch task" do
    rp = runn_project!
    pt = tracker!(rp, rate: 200)
    assign!(runn_person!("ok#{@seq}@example.com"), rp, runn_role!(200))
    assert_nil discover.find { |x| x.subject == pt }
  end

  # --- stale sync ----------------------------------------------------------

  test "a stale or never-run Runn sync is a task for the admin team" do
    System.first.update!(runn_synced_at: 5.days.ago)
    t = discover.find { |x| x.type == :runn_sync_stale }
    assert_equal System.first, t.subject
    assert_equal [@admin], t.owners
    assert_match(/last synced/, t.subject_display_name)
    assert_equal "/admin/system_tasks", t.subject_url

    System.first.update!(runn_synced_at: nil)
    assert_equal "Runn mirror (never synced)", discover.find { |x| x.type == :runn_sync_stale }.subject_display_name
  end

  test "a fresh sync produces no stale task" do
    assert_nil discover.find { |x| x.type == :runn_sync_stale }
  end
end
