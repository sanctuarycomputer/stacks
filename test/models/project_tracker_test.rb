require "test_helper"

class ProjectTrackerTest < ActiveSupport::TestCase
  test "likely_complete? is true when snapshot end date is old and capsule is not complete" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "last_forecast_assignment_end_date" => (Date.today - 2.months).iso8601,
    })

    assert_predicate pt, :likely_complete?
  end

  test "likely_complete? is false when name matches considered_ongoing?" do
    pt = ProjectTracker.new(name: "Something ongoing")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "last_forecast_assignment_end_date" => (Date.today - 2.months).iso8601,
    })

    assert_not pt.likely_complete?
  end

  test "likely_complete? is false when snapshot end date is recent" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "last_forecast_assignment_end_date" => Date.today.iso8601,
    })

    assert_not pt.likely_complete?
  end

  test "likely_complete? is false when snapshot end date is missing" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {})

    assert_not pt.likely_complete?
  end

  test "likely_complete? is false when project_capsule has all four statuses set" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "last_forecast_assignment_end_date" => (Date.today - 2.months).iso8601,
    })
    ProjectCapsule.create!(
      project_tracker: pt,
      client_feedback_survey_status: :no_response_from_client,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
    )

    assert_not pt.reload.likely_complete?
  end

  test "dormant scope filters on snapshot last_forecast_assignment_end_date" do
    sql = ProjectTracker.dormant.to_sql
    assert_includes sql, "last_forecast_assignment_end_date"
    assert_includes sql, "snapshot"
  end

  test "in_progress scope generates SQL without loading ids in Ruby" do
    sql = ProjectTracker.in_progress.to_sql
    assert_predicate sql, :present?
    assert_includes sql, "project_trackers"
  end

  test "first_recorded_assignment_start_date and last_recorded_assignment_end_date read snapshot when set" do
    pt = ProjectTracker.new(name: "Snapshot bounds")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {
      "first_forecast_assignment_start_date" => "2024-01-10",
      "last_forecast_assignment_end_date" => "2024-06-30",
    })

    assert_equal Date.new(2024, 1, 10), pt.reload.first_recorded_assignment_start_date
    assert_equal Date.new(2024, 6, 30), pt.last_recorded_assignment_end_date
  end

  test "batch-cached edge assignments expose Date bounds, not raw SQL strings" do
    pt = ProjectTracker.new(name: "Edge assignment bounds")
    pt.save!(validate: false)
    pt.update_column(:snapshot, {}) # no snapshot bounds -> forces the edge-assignment fallback

    fp = ForecastProject.new(forecast_id: 987_654, name: "FP", client_id: 123_456)
    fp.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: fp)
    fa = ForecastAssignment.new(
      project_id: fp.forecast_id,
      start_date: Date.new(2021, 6, 23),
      end_date: Date.new(2022, 3, 31),
    )
    fa.save!(validate: false)

    # preload_for_render runs batch_cache_edge_recorded_assignments!, the path the
    # admin index uses (and the only path that populates @_first_recorded_assignment
    # from raw SQL).
    ProjectTracker.preload_for_render([pt])

    assert_instance_of Date, pt.first_recorded_assignment_start_date
    assert_equal Date.new(2021, 6, 23), pt.first_recorded_assignment_start_date
    assert_instance_of Date, pt.last_recorded_assignment_end_date
    assert_equal Date.new(2022, 3, 31), pt.last_recorded_assignment_end_date
  end

  test "lifetime_commissions_paid sums as_commission across all CPs on this tracker's invoices" do
    pt = ProjectTracker.new(name: "Commission Total Test")
    pt.save!(validate: false)

    cp1 = ContributorPayout.new(amount: 50, blueprint: { "Commission" => [{ "amount" => 50 }] })
    cp2 = ContributorPayout.new(amount: 30, blueprint: { "Commission" => [{ "amount" => 30 }] })
    cp3 = ContributorPayout.new(amount: 100, blueprint: { "IndividualContributor" => [{ "amount" => 100 }] })

    invoice_tracker = mock("invoice_tracker")
    invoice_tracker.stubs(:contributor_payouts).returns([cp1, cp2, cp3])
    pt.stubs(:invoice_trackers).returns([invoice_tracker])

    assert_in_delta 80.0, pt.lifetime_commissions_paid, 0.001
  end

  # A client with separate Design and Development trackers shares one
  # client-level InvoiceTracker, so both trackers see the same payouts.
  # monthly_cosr has to split them by each blueprint entry's forecast_project,
  # or both projects book the full cost and both margins crater.
  test "monthly_cosr attributes a shared client payout to each tracker by forecast project" do
    enterprise = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    forecast_client = ForecastClient.create!(forecast_id: 90_100_001, name: "Split Client")
    invoice_pass = InvoicePass.find_or_create_by!(start_of_month: Date.new(2026, 6, 1))
    qbo_account = enterprise.qbo_account || QboAccount.create!(
      enterprise: enterprise,
      client_id: "test_client",
      client_secret: "test_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )
    invoice_tracker = InvoiceTracker.create!(
      forecast_client: forecast_client,
      invoice_pass: invoice_pass,
      qbo_account: qbo_account,
    )

    design_fp = ForecastProject.create!(forecast_id: 90_200_001, name: "Design", code: "SPL-1", client_id: forecast_client.forecast_id)
    dev_fp = ForecastProject.create!(forecast_id: 90_200_002, name: "Development", code: "SPL-2", client_id: forecast_client.forecast_id)

    design = ProjectTracker.new(name: "Split Design")
    design.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: design, forecast_project_id: design_fp.forecast_id)

    dev = ProjectTracker.new(name: "Split Development")
    dev.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: dev, forecast_project_id: dev_fp.forecast_id)

    person = ForecastPerson.create!(forecast_id: 90_300_001, first_name: "Lead", last_name: "Person", email: "lead-#{SecureRandom.hex(3)}@example.com")
    contributor = Contributor.create!(forecast_person_id: person.forecast_id)
    ledger = Ledger.find_by!(contributor: contributor, enterprise: enterprise)

    payout = ContributorPayout.new(
      invoice_tracker: invoice_tracker,
      ledger: ledger,
      created_by: AdminUser.first || AdminUser.create!(email: "admin-#{SecureRandom.hex(3)}@example.com", password: SecureRandom.hex(8)),
      amount: 3310.50,
      blueprint: {
        "AccountLead" => [
          { "amount" => 228.0, "blueprint_metadata" => { "forecast_project" => dev_fp.forecast_id } },
          { "amount" => 336.0, "blueprint_metadata" => { "forecast_project" => design_fp.forecast_id } },
        ],
        "ProjectLead" => [
          { "amount" => 142.5, "blueprint_metadata" => { "forecast_project" => dev_fp.forecast_id } },
          { "amount" => 210.0, "blueprint_metadata" => { "forecast_project" => design_fp.forecast_id } },
        ],
        "IndividualContributor" => [
          { "amount" => 2394.0, "blueprint_metadata" => { "forecast_project" => design_fp.forecast_id } },
        ],
        "Commission" => [],
      },
    )
    payout.save!(validate: false)

    design.stubs(:invoice_trackers).returns([invoice_tracker])
    dev.stubs(:invoice_trackers).returns([invoice_tracker])

    accrual = invoice_pass.start_of_month.end_of_month
    design_cost = design.monthly_cosr[accrual].values.sum { |c| c[:amount] }
    dev_cost = dev.monthly_cosr[accrual].values.sum { |c| c[:amount] }

    assert_in_delta 2940.0, design_cost, 0.001
    assert_in_delta 370.5, dev_cost, 0.001
    assert_in_delta payout.amount, design_cost + dev_cost, 0.001
  end

  # income_series is the extracted admin burn-up income assembly
  # (app/admin/project_trackers.rb show block) — same ordering (invoice
  # due_date, falling back to the tracker row's created_at), same
  # attribution rules (tracker-attributable line items for InvoiceTrackers,
  # the whole invoice total for adhoc), same {x:, y: 0} seed point.
  test "income_series accumulates attributable invoice income sorted by due date with a seed point" do
    enterprise = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    qbo_account = enterprise.qbo_account || QboAccount.create!(
      enterprise: enterprise,
      client_id: "test_client",
      client_secret: "test_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )
    forecast_client = ForecastClient.create!(forecast_id: 90_400_001, name: "Income Client")
    fp = ForecastProject.create!(forecast_id: 90_400_002, name: "Income Project", code: "INC-1", client_id: forecast_client.forecast_id)
    other_fp = ForecastProject.create!(forecast_id: 90_400_003, name: "Other Project", code: "OTH-1", client_id: forecast_client.forecast_id)

    pt = ProjectTracker.new(name: "Income Series Test")
    pt.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project_id: fp.forecast_id)
    pt.update_column(:snapshot, { "first_forecast_assignment_start_date" => "2026-01-01" })
    pt = ProjectTracker.find(pt.id)

    # A generated invoice for June: only the line item attributed to this
    # tracker's forecast project counts (1000.0) — the 999.0 line belongs
    # to a different tracker on the same client-level invoice.
    generated_invoice = QboInvoice.create!(qbo_account: qbo_account, qbo_id: "inc-gen", data: {
      "due_date" => "2026-06-15",
      "line_items" => [
        { "id" => "li-1", "description" => "INC-1 work", "amount" => 1000.0, "detail_type" => "SalesItemLineDetail",
          "sales_line_item_detail" => { "quantity" => 10.0, "unit_price" => 100.0 } },
        { "id" => "li-2", "description" => "OTH-1 work", "amount" => 999.0, "detail_type" => "SalesItemLineDetail",
          "sales_line_item_detail" => { "quantity" => 9.0, "unit_price" => 111.0 } },
      ],
    })
    InvoiceTracker.create!(
      forecast_client: forecast_client,
      invoice_pass: InvoicePass.find_or_create_by!(start_of_month: Date.new(2026, 5, 1)),
      qbo_account: qbo_account,
      qbo_invoice_id: generated_invoice.qbo_id,
      blueprint: { "lines" => {
        "INC-1 work" => { "id" => "li-1", "forecast_project" => fp.forecast_id, "quantity" => 10.0, "unit_price" => 100.0 },
        "OTH-1 work" => { "id" => "li-2", "forecast_project" => other_fp.forecast_id, "quantity" => 9.0, "unit_price" => 111.0 },
      } },
    )

    # An adhoc invoice due earlier (May): its WHOLE total counts.
    adhoc_invoice = QboInvoice.create!(qbo_account: qbo_account, qbo_id: "inc-adhoc", data: {
      "due_date" => "2026-05-15",
      "total" => 500.0,
    })
    AdhocInvoiceTracker.create!(project_tracker: pt, qbo_account: qbo_account, qbo_invoice_id: adhoc_invoice.qbo_id)

    # An adhoc invoice with no due_date in its synced data: falls back to
    # the tracker row's created_at (today), so it sorts last.
    no_due_invoice = QboInvoice.create!(qbo_account: qbo_account, qbo_id: "inc-nodue", data: { "total" => 200.0 })
    no_due_row = AdhocInvoiceTracker.create!(project_tracker: pt, qbo_account: qbo_account, qbo_invoice_id: no_due_invoice.qbo_id)

    series = pt.income_series

    assert_equal [
      { x: "2026-01-01", y: 0 },
      { x: "2026-05-15", y: 500.0 },
      { x: "2026-06-15", y: 1500.0 },
      { x: no_due_row.created_at.to_date.iso8601, y: 1700.0 },
    ], series[:income]
    assert_in_delta 1700.0, series[:income_total], 0.001
  end
end
