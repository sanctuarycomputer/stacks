require "test_helper"

# Every test builds its own rows. Horizon is pinned to Sep–Dec 2026.
# Sep 7–11 2026 is Mon–Fri: a 480 min/day assignment = 40 hours.
class ContributorProjections::BuildTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 9, 8)
  SEP = Date.new(2026, 9, 1)
  OCT = Date.new(2026, 10, 1)

  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.sanctuary
    @seq = 800_000 + rand(100_000)
  end

  def nid
    @seq += 1
  end

  def horizon
    ContributorProjections::Horizon.current(TODAY)
  end

  def build(contributor: nil)
    ContributorProjections::Build.call(horizon: horizon, contributor: contributor)
  end

  # --- builders --------------------------------------------------------

  def person!(email, admin: false, ftp: nil)
    fp = ForecastPerson.create!(forecast_id: nid, email: email, data: {})
    if admin || ftp
      au = AdminUser.create!(email: email, password: "password123", password_confirmation: "password123")
      if ftp
        FullTimePeriod.create!(admin_user: au, started_at: Date.new(2025, 1, 1), ended_at: ftp == :ended ? Date.new(2026, 6, 30) : nil,
                               contributor_type: ftp == :ended ? :five_day : ftp)
      end
    end
    fp.reload
  end

  def runn_person!(email)
    RunnPerson.create!(runn_id: nid, first_name: "R", last_name: "P", email: email)
  end

  def runn_role!(rate)
    RunnRole.create!(runn_id: nid, name: "$#{rate}.00 p/h", standard_rate: rate, default_hour_cost: 0)
  end

  def client!(internal_to: nil)
    fc = ForecastClient.create!(forecast_id: nid, name: "Client #{@seq}")
    EnterpriseForecastClient.create!(enterprise: internal_to, forecast_client_id: fc.forecast_id) if internal_to
    fc
  end

  def workstream!(client, rate: 200, notes: nil, tags: nil, archived: false)
    ForecastProject.create!(forecast_id: nid, client_id: client.forecast_id, name: "WS #{@seq}", code: "WS-#{@seq}",
                            tags: tags || ["#{rate}p/h"], notes: notes, archived: archived)
  end

  def tracker!(workstreams, model: "new_deal_v1", confirmed: true, archived: false)
    rp = RunnProject.create!(runn_id: nid, name: "RP #{@seq}", is_confirmed: confirmed, is_archived: archived, is_template: false)
    pt = ProjectTracker.new(name: "Tracker #{@seq}", billing_model: model, runn_project_id: rp.runn_id)
    pt.save!(validate: false)
    workstreams.each { |ws| ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: ws) }
    pt
  end

  def assign!(runn_person, tracker, role, start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 11), minutes: 480, billable: true, placeholder: false, non_working_day: false)
    RunnAssignment.create!(runn_id: nid, person_id: runn_person.runn_id, project_id: tracker.runn_project_id, role_id: role.runn_id,
                           start_date: start_date, end_date: end_date, minutes_per_day: minutes, is_billable: billable,
                           is_placeholder: placeholder, is_non_working_day: non_working_day)
  end

  def lead!(klass, tracker, admin_user, started_at: nil, ended_at: nil)
    klass.create!(project_tracker: tracker, admin_user: admin_user, started_at: started_at, ended_at: ended_at)
  end

  def lines_for(result, forecast_person, kind: nil, month: SEP)
    result.lines.select do |l|
      l.contributor_id == forecast_person.contributor.id &&
        (month.nil? || l.month == month) &&
        (kind.nil? || l.kind == kind)
    end
  end

  def amount_for(result, forecast_person, kind:, month: SEP)
    lines_for(result, forecast_person, kind: kind, month: month).sum(&:amount)
  end

  # A standard external setup: IC + AL + PL on one v1 tracker, 40h at $200.
  def standard_setup(model: "new_deal_v1", notes: nil)
    @ic = person!("ic-#{@seq}@example.com")
    @al = person!("al-#{@seq}@example.com", admin: true)
    @pl = person!("pl-#{@seq}@example.com", admin: true)
    @client = client!
    @ws = workstream!(@client, rate: 200, notes: notes)
    @pt = tracker!([@ws], model: model)
    lead!(AccountLeadPeriod, @pt, @al.admin_user, started_at: Date.new(2026, 8, 1))
    lead!(ProjectLeadPeriod, @pt, @pl.admin_user, started_at: Date.new(2026, 8, 1))
    @role = runn_role!(200)
    @rp_ic = runn_person!(@ic.email)
    assign!(@rp_ic, @pt, @role)
  end

  # --- pricing ---------------------------------------------------------

  test "external client on new_deal_v1: IC 57%, AL 8%, PL 5%, no surplus" do
    standard_setup
    r = build
    assert_in_delta 4560.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 8000 * 0.57
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01               # 8000 * 0.08
    assert_in_delta 400.0, amount_for(r, @pl, kind: :project_lead), 0.01               # 8000 * 0.05
    assert_empty r.lines.select { |l| l.kind.to_s.end_with?("surplus") }
    ic = lines_for(r, @ic, kind: :individual_contributor).first
    assert_equal "- 40.0 hrs * $200.00 p/h * 57.0% = $4,560.00", ic.description
    assert_equal @pt.id, ic.project_tracker_id
    assert_equal @sanctuary.id, ic.enterprise_id
    assert_equal Ledger.find_by!(enterprise: @sanctuary, contributor: @ic.contributor).id, ic.ledger_id
    assert_equal 40.0, ic.hours
    assert_not ic.tentative
    assert_not ic.rate_mismatch
  end

  test "external client on new_deal_v2: IC 54%, surplus zero" do
    standard_setup(model: "new_deal_v2")
    r = build
    assert_in_delta 4320.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 8000 * 0.54
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01
    assert_empty r.lines.select { |l| l.kind.to_s.end_with?("surplus") }
  end

  test "override below the ceiling on v2 yields surplus split 15% to each lead" do
    standard_setup(model: "new_deal_v2", notes: "ic-#{@seq}@example.com:80p/h")
    r = build
    assert_in_delta 3200.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 40 * 80
    # margin = (8000 - 3200) / 8000 = 0.60; surplus = (0.60 - 0.46) * 8000 = 1120; 15% = 168
    assert_in_delta 168.0, amount_for(r, @al, kind: :account_lead_surplus), 0.01
    assert_in_delta 168.0, amount_for(r, @pl, kind: :project_lead_surplus), 0.01
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01, "AL 8% unchanged by the override"
  end

  test "a 0p/h override emits no IC line and no surplus" do
    standard_setup(notes: "ic-#{@seq}@example.com:0p/h")
    r = build
    assert_empty lines_for(r, @ic)
    assert_empty r.lines.select { |l| l.kind.to_s.end_with?("surplus") }
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01
  end

  test "commissions come off the top before the split and land on the recipient's ledger" do
    standard_setup
    rec = person!("rec-#{@seq}@example.com")
    PerHourCommission.create!(project_tracker: @pt, contributor: rec.contributor, rate: 10)       # 40 * 10 = 400
    PercentageCommission.create!(project_tracker: @pt, contributor: rec.contributor, rate: 0.05)  # 8000 * 0.05 = 400
    r = build
    assert_in_delta 800.0, amount_for(r, rec, kind: :commission), 0.01
    # working = 8000 - 800 = 7200
    assert_in_delta 4104.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 7200 * 0.57
    assert_in_delta 576.0, amount_for(r, @al, kind: :account_lead), 0.01              # 7200 * 0.08
  end

  test "internal client prices a single pay_stub line on that enterprise's ledger with no splits" do
    internal = Enterprise.find_or_create_by!(name: "Internal Ent #{@seq}")
    ic = person!("int-#{@seq}@example.com")
    al = person!("intal-#{@seq}@example.com", admin: true)
    client = client!(internal_to: internal)
    ws = workstream!(client, rate: 100)
    pt = tracker!([ws])
    lead!(AccountLeadPeriod, pt, al.admin_user, started_at: Date.new(2026, 8, 1))
    PerHourCommission.create!(project_tracker: pt, contributor: al.contributor, rate: 10)
    assign!(runn_person!(ic.email), pt, runn_role!(100))
    r = build
    stub = lines_for(r, ic, kind: :pay_stub).first
    assert_in_delta 4000.0, stub.amount, 0.01                      # 40 * 100
    assert_equal Ledger.find_by!(enterprise: internal, contributor: ic.contributor).id, stub.ledger_id
    assert_empty lines_for(r, al), "no AL share and no commission on internal work"
  end

  test "internal client with no explicit rate and no override is skipped under no_explicit_rate" do
    internal = Enterprise.find_or_create_by!(name: "Internal Ent #{@seq}")
    ic = person!("int2-#{@seq}@example.com")
    client = client!(internal_to: internal)
    ws = workstream!(client, tags: [])
    pt = tracker!([ws])
    assign!(runn_person!(ic.email), pt, runn_role!(175))
    r = build
    assert_empty lines_for(r, ic)
    assert_equal 1, r.skipped[:no_explicit_rate]
  end

  # --- payees and leads -------------------------------------------------

  test "salaried lead gets no line but still reduces the IC share" do
    @ic = person!("ic-#{@seq}@example.com")
    @al = person!("al-#{@seq}@example.com", ftp: :five_day)
    @client = client!
    @ws = workstream!(@client, rate: 200)
    @pt = tracker!([@ws])
    lead!(AccountLeadPeriod, @pt, @al.admin_user, started_at: Date.new(2026, 8, 1))
    assign!(runn_person!(@ic.email), @pt, runn_role!(200))
    r = build
    assert_empty lines_for(r, @al)
    assert_in_delta 4960.0, amount_for(r, @ic, kind: :individual_contributor), 0.01   # 8000 * (1 - 0.30 - 0.08)
  end

  test "variable_hours payee and ex-employee payee are both paid" do
    v = person!("v-#{@seq}@example.com", ftp: :variable_hours)
    x = person!("x-#{@seq}@example.com", ftp: :ended)
    client = client!
    ws = workstream!(client, rate: 200)
    pt = tracker!([ws])
    role = runn_role!(200)
    assign!(runn_person!(v.email), pt, role)
    assign!(runn_person!(x.email), pt, role)
    r = build
    assert_in_delta 5600.0, amount_for(r, v, kind: :individual_contributor), 0.01     # 8000 * 0.70 (no leads)
    assert_in_delta 5600.0, amount_for(r, x, kind: :individual_contributor), 0.01
  end

  test "open-ended lead period with nil started_at resolves in a future month; an ended one does not" do
    @ic = person!("ic-#{@seq}@example.com")
    open_lead = person!("open-#{@seq}@example.com", admin: true)
    ended_lead = person!("ended-#{@seq}@example.com", admin: true)
    @client = client!
    @ws = workstream!(@client, rate: 200)
    @pt = tracker!([@ws])
    # period_started_at falls back to the tracker's first recorded assignment
    # (read from the snapshot) when started_at is nil — pin it so the test
    # does not depend on the real calendar date.
    @pt.update_column(:snapshot, { "first_forecast_assignment_start_date" => "2026-01-05" })
    lead!(AccountLeadPeriod, @pt, open_lead.admin_user, started_at: nil, ended_at: nil)
    lead!(ProjectLeadPeriod, @pt, ended_lead.admin_user, started_at: Date.new(2026, 1, 1), ended_at: Date.new(2026, 8, 31))
    assign!(runn_person!(@ic.email), @pt, runn_role!(200), start_date: Date.new(2026, 10, 5), end_date: Date.new(2026, 10, 9))
    r = build
    assert_in_delta 640.0, amount_for(r, open_lead, kind: :account_lead, month: OCT), 0.01
    assert_empty lines_for(r, ended_lead, month: OCT)
    assert_in_delta 4960.0, amount_for(r, @ic, kind: :individual_contributor, month: OCT), 0.01  # no PL → 62%
  end

  test "open-ended lead period is treated as continuing even though account_lead_for_month returns nil for future months" do
    @ic = person!("ic-#{@seq}@example.com")
    al = person!("al-#{@seq}@example.com", admin: true)
    client = client!
    ws = workstream!(client, rate: 200)
    pt = tracker!([ws])
    lead!(AccountLeadPeriod, pt, al.admin_user, started_at: Date.new(2026, 8, 1), ended_at: nil)
    pt.update_column(:snapshot, { "first_forecast_assignment_start_date" => "2026-08-03", "last_forecast_assignment_end_date" => "2026-08-28" })
    assign!(runn_person!(@ic.email), pt, runn_role!(200), start_date: Date.new(2026, 10, 5), end_date: Date.new(2026, 10, 9))
    assert_nil pt.account_lead_for_month(Date.new(2026, 10, 1))
    r = build
    assert_in_delta 640.0, amount_for(r, al, kind: :account_lead, month: OCT), 0.01
  end

  # --- resolve --------------------------------------------------------

  test "two assignments for one person on one workstream in one month are priced once" do
    standard_setup(model: "new_deal_v2", notes: "ic-#{@seq}@example.com:80.005p/h")
    assign!(@rp_ic, @pt, @role, start_date: Date.new(2026, 9, 14), end_date: Date.new(2026, 9, 18))
    r = build
    ic_lines = lines_for(r, @ic, kind: :individual_contributor)
    assert_equal 1, ic_lines.size
    assert_equal 80.0, ic_lines.first.hours
    assert_in_delta 6400.4, ic_lines.first.amount, 0.001   # 80 * 80.005 rounded once
    assert_equal 1, lines_for(r, @al, kind: :account_lead_surplus).size
  end

  test "hours split across months, weekends excluded, non-working-day counts every day" do
    standard_setup
    RunnAssignment.delete_all
    assign!(@rp_ic, @pt, @role, start_date: Date.new(2026, 9, 28), end_date: Date.new(2026, 10, 2))   # Mon–Fri across the boundary
    assign!(@rp_ic, @pt, @role, start_date: Date.new(2026, 9, 12), end_date: Date.new(2026, 9, 13), minutes: 60, non_working_day: true)  # Sat–Sun
    r = build
    assert_equal 26.0, lines_for(r, @ic, kind: :individual_contributor).first.hours          # 3 days * 8h + 2 days * 1h
    assert_equal 16.0, lines_for(r, @ic, kind: :individual_contributor, month: OCT).first.hours
  end

  test "assignments beyond the horizon are clipped and past months are never emitted" do
    standard_setup
    RunnAssignment.delete_all
    assign!(@rp_ic, @pt, @role, start_date: Date.new(2026, 8, 24), end_date: Date.new(2027, 1, 8))
    r = build
    assert_equal horizon.month_keys.sort, lines_for(r, @ic, kind: :individual_contributor, month: nil).map(&:month).sort.uniq
  end

  test "tentative Runn projects flag their lines" do
    @ic = person!("ic-#{@seq}@example.com")
    client = client!
    ws = workstream!(client, rate: 200)
    pt = tracker!([ws], confirmed: false)
    assign!(runn_person!(@ic.email), pt, runn_role!(200))
    r = build
    assert lines_for(r, @ic, kind: :individual_contributor).first.tentative
    assert_in_delta 5600.0, r.totals_by_month[SEP][:tentative_amount], 0.01
  end

  test "role rate matching no workstream falls back to the first unarchived workstream and flags rate_mismatch" do
    @ic = person!("ic-#{@seq}@example.com")
    client = client!
    archived = workstream!(client, rate: 150, archived: true)
    live = workstream!(client, rate: 225)
    pt = tracker!([archived, live])
    assign!(runn_person!(@ic.email), pt, runn_role!(999))
    r = build
    ic = lines_for(r, @ic, kind: :individual_contributor).first
    assert ic.rate_mismatch
    assert_equal 225.0, ic.rate
    assert_in_delta 40 * 225 * 0.70, ic.amount, 0.01
    assert_equal 1, r.skipped[:role_rate_mismatch]
  end

  test "role rate selects the matching workstream on a multi-rate tracker" do
    @ic = person!("ic-#{@seq}@example.com")
    client = client!
    ws150 = workstream!(client, rate: 150)
    ws225 = workstream!(client, rate: 225, notes: "#{@ic.email}:100p/h")   # @seq has moved on since person!; use the real email
    pt = tracker!([ws150, ws225])
    assign!(runn_person!(@ic.email), pt, runn_role!(225))
    r = build
    ic = lines_for(r, @ic, kind: :individual_contributor).first
    assert_not ic.rate_mismatch
    assert_equal 100.0, ic.rate, "override read from the matched workstream"
    assert_in_delta 4000.0, ic.amount, 0.01
  end

  test "unmapped person, placeholder, unmapped project, non-billable, archived project, no workstream are skipped" do
    client = client!
    ws = workstream!(client, rate: 200)
    pt = tracker!([ws])
    role = runn_role!(200)
    stranger = runn_person!("stranger-#{@seq}@example.com")
    assign!(stranger, pt, role)                                             # unmapped_person
    ic = person!("ic-#{@seq}@example.com")
    rp_ic = runn_person!(ic.email)
    assign!(rp_ic, pt, role, placeholder: true)                             # unmapped_person (placeholder)
    assign!(rp_ic, pt, role, billable: false)                               # non_billable
    orphan_rp = RunnProject.create!(runn_id: nid, name: "Orphan", is_confirmed: true, is_archived: false, is_template: false)
    RunnAssignment.create!(runn_id: nid, person_id: rp_ic.runn_id, project_id: orphan_rp.runn_id, role_id: role.runn_id,
                           start_date: Date.new(2026, 9, 7), end_date: Date.new(2026, 9, 11), minutes_per_day: 480)   # unmapped_project
    archived_pt = tracker!([workstream!(client, rate: 200)], archived: true)  # own workstream: a workstream may link to one tracker only
    assign!(rp_ic, archived_pt, role)                                       # silent
    bare_pt = tracker!([])
    assign!(rp_ic, bare_pt, role)                                           # no_forecast_project

    r = build
    assert_empty r.lines
    assert_equal 2, r.skipped[:unmapped_person]
    assert_equal 1, r.skipped[:non_billable]
    assert_equal 1, r.skipped[:unmapped_project]
    assert_equal 1, r.skipped[:no_forecast_project]
    assert_nil r.skipped[:archived]
    assert_includes r.skipped_details[:unmapped_project], "Orphan"
  end

  test "a workstream linked to two trackers is skipped as ambiguous_tracker" do
    ic = person!("ic-#{@seq}@example.com")
    client = client!
    ws = workstream!(client, rate: 200)
    pt = tracker!([ws])
    other = ProjectTracker.new(name: "Other #{@seq}"); other.save!(validate: false)
    ProjectTrackerForecastProject.new(project_tracker: other, forecast_project: ws).save!(validate: false)
    assign!(runn_person!(ic.email), pt, runn_role!(200))
    r = build
    assert_empty r.lines
    assert_equal 1, r.skipped[:ambiguous_tracker]
  end

  test "missing ledger is counted and the line dropped" do
    standard_setup
    Ledger.where(enterprise: @sanctuary, contributor: @ic.contributor).delete_all
    r = build
    assert_empty lines_for(r, @ic)
    assert_equal 1, r.skipped[:no_ledger]
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01, "other payees unaffected"
  end

  # --- recurring adjustments ---------------------------------------------

  test "recurring ledger adjustments are projected by cadence inside the horizon" do
    ic = person!("rla-#{@seq}@example.com")
    ledger = Ledger.find_by!(enterprise: @sanctuary, contributor: ic.contributor)
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 25, description: "Monthly stipend", cadence: "monthly", next_due_on: Date.new(2026, 9, 15))
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 10, description: "Twice", cadence: "twice_monthly", next_due_on: Date.new(2026, 8, 15))
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 100, description: "Quarterly", cadence: "quarterly", next_due_on: Date.new(2026, 10, 1))
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 999, description: "Paused", cadence: "monthly", next_due_on: Date.new(2026, 9, 1), paused_at: Time.current)
    r = build
    by = r.by_contributor_month(ic.contributor)
    assert_in_delta 25 + 20, by[SEP][:amount], 0.01          # monthly + two twice_monthly (Sep 1, Sep 15); Aug 15 is before the horizon
    assert_in_delta 25 + 20 + 100, by[OCT][:amount], 0.01
    assert_in_delta 25 + 20, by[Date.new(2026, 11, 1)][:amount], 0.01
    assert_in_delta 25 + 20, by[Date.new(2026, 12, 1)][:amount], 0.01
    assert_equal :recurring_adjustment, by[SEP][:lines].first.kind
  end

  test "a recurring adjustment with an invalid cadence is skipped without raising, and a valid sibling still projects" do
    ic = person!("rla-#{@seq}@example.com")
    ledger = Ledger.find_by!(enterprise: @sanctuary, contributor: ic.contributor)
    bad = RecurringLedgerAdjustment.create!(ledger: ledger, amount: 25, description: "Bad cadence", cadence: "monthly", next_due_on: Date.new(2026, 9, 10))
    bad.update_column(:cadence, "weekly") # bypass validation to simulate a corrupt row
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 50, description: "Good", cadence: "monthly", next_due_on: Date.new(2026, 9, 15))
    r = nil
    assert_nothing_raised { r = build }
    assert_equal 1, r.skipped[:invalid_recurring_adjustment]
    assert_includes r.skipped_details[:invalid_recurring_adjustment].first, "##{bad.id}"
    by = r.by_contributor_month(ic.contributor)
    # The bad row's already-due Sep 10 occurrence still projects (its cadence
    # only breaks when computing the *next* due date); the good row projects
    # every month of the horizon, proving the bad row didn't take it down.
    assert_in_delta 25 + 50, by[SEP][:amount], 0.01
    assert_in_delta 50.0, by[OCT][:amount], 0.01
  end

  # --- filtering and caching ------------------------------------------------

  test "contributor: keeps only that contributor's lines, including lead lines earned from others' hours" do
    standard_setup
    r = build(contributor: @al.contributor)
    assert_equal [@al.contributor.id], r.lines.map(&:contributor_id).uniq
    assert_in_delta 640.0, amount_for(r, @al, kind: :account_lead), 0.01
  end

  test "as_of comes from System and cached_all memoizes per sync stamp" do
    standard_setup
    s = System.first || System.create!(settings: {})
    s.update!(runn_synced_at: DateTime.new(2026, 9, 8, 2))
    assert_equal DateTime.new(2026, 9, 8, 2).to_i, build.as_of.to_i
    # memory_store marshals entries; a Result must survive that (no default-proc hashes, no AR objects)
    assert_nothing_raised { ActiveSupport::Cache::MemoryStore.new.write("probe", build) }

    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(store)
    ContributorProjections::Build.expects(:call).once.returns(:first)
    assert_equal :first, ContributorProjections::Build.cached_all(horizon: horizon)
    assert_equal :first, ContributorProjections::Build.cached_all(horizon: horizon)
    System.first.update!(runn_synced_at: DateTime.new(2026, 9, 9, 2))
    ContributorProjections::Build.expects(:call).once.returns(:second)
    assert_equal :second, ContributorProjections::Build.cached_all(horizon: horizon)
  end
end
