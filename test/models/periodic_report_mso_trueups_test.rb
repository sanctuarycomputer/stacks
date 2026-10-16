require "test_helper"

# MSO true-ups hang off a monthly PeriodicReport as profit shares hang off a
# quarterly one (spec 13d).
class PeriodicReportMsoTrueupsTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2093, 5, 1)
  TODAY = Date.new(2093, 6, 10)

  def setup
    build_mso_month(MONTH)
    @report = mso_report(MONTH)
    # report_exception posts to Twist; the Notification row it makes is real.
    Stacks::Notifications.stubs(:twist).returns(stub(add_comment_to_thread: nil))
  end

  def teardown
    clear_enterprise_memos
  end

  def sync!(report = @report, today: TODAY)
    report = PeriodicReport.find(report.id)
    report.sync_mso_trueups!(today: today)
    report.reload
  end

  def trueup_for(contributor, report: @report)
    MsoTrueup.find_by(periodic_report_id: report.id, ledger_id: garden3d_ledger(contributor).id)
  end

  def rows
    MsoTrueup.with_deleted.where(periodic_report_id: @report.id).order(:id)
      .map { |row| [row.id, row.ledger_id, row.amount, row.accepted_at, row.deleted_at, row.blueprint] }
  end

  # --- the report --------------------------------------------------------------

  test "a monthly report's period is its month; a quarterly report's is still its quarter" do
    assert_equal [MONTH, Date.new(2093, 5, 31)], [@report.period.starts_at, @report.period.ends_at]

    quarter = PeriodicReport.create!(period_gradation: :quarter, period_starts_at: Date.new(2093, 4, 1),
                                     period_label: "Q2, 2093")
    assert_equal Date.new(2093, 6, 30), quarter.period.ends_at
  end

  test "each kind of sync belongs to its own kind of report" do
    quarter = PeriodicReport.create!(period_gradation: :quarter, period_starts_at: Date.new(2093, 4, 1),
                                     period_label: "Q2, 2093")

    assert_raises(ArgumentError) { quarter.sync_mso_trueups! }
    assert_raises(ArgumentError) { @report.sync_profit_shares! }
    assert_equal 0, MsoTrueup.count
    assert_equal 0, ProfitShare.where(periodic_report_id: @report.id).count
  end

  test "the monthly reports are made from the first MSO month through last month, once" do
    PeriodicReport.month.delete_all
    start = InvoicePass::INTERCOMPANY_START

    assert_difference -> { PeriodicReport.month.count }, 3 do
      PeriodicReport.ensure_monthly_reports_exist!(today: start + 3.months + 9.days)
    end
    assert_no_difference -> { PeriodicReport.count } do
      PeriodicReport.ensure_monthly_reports_exist!(today: start + 3.months + 9.days)
    end

    assert_equal [start, start + 1.month, start + 2.months], PeriodicReport.month.order(:period_starts_at).pluck(:period_starts_at)
    assert_equal start.strftime("%B %Y"), PeriodicReport.month.find_by!(period_starts_at: start).period_label
    assert_equal "August 2026", PeriodicReport.month.order(:period_starts_at).first.period_label
  end

  # --- what a sync writes --------------------------------------------------------

  test "each executive owed money gets one unaccepted true-up on their garden3d ledger" do
    report = sync!

    assert_nil report.notification
    chief = trueup_for(@chief)
    principal = trueup_for(@principal)
    assert_equal [BigDecimal("20000"), BigDecimal("23000")], [chief.amount, principal.amount]
    assert_equal [false, false], [chief.accepted?, principal.accepted?]
    assert_equal garden3d.id, chief.ledger.enterprise_id
    assert_equal Date.new(2093, 5, 31), chief.payment_date
    assert_equal @chief_role.id, chief.blueprint["mso_role_period_id"]
    assert_equal %w[chief 1.0 20000.0 20000.0 0.0 20000.0],
      chief.blueprint.values_at("tier", "multiplier", "calculated", "final", "already_earned", "trueup")
    assert_match(/MSO true-up for May 2093/, chief.description)
    assert_match(/\$20,000\.00/, chief.description)
    assert_equal 2, report.mso_trueups.count
  end

  test "the report's blueprint holds the month's figures" do
    blueprint = sync!.blueprint

    assert blueprint["generated_at"].present?
    assert_equal "100000.0", blueprint["fee_income"]
    assert_equal BigDecimal("55000"), BigDecimal(blueprint["cap"])
    assert_equal "0.55", blueprint["cap_percentage"]
    assert_equal "20000.0", blueprint["benchmark_average"]
    assert_equal [3, 3, false], blueprint.values_at("configured_n", "counted", "small_sample")
    assert_equal "43000.0", blueprint["total_calculated"]
    assert_equal "43000.0", blueprint["total_trueup"]
    assert_equal "0.0", blueprint.dig("reconciliation", "variance")
    assert_equal ["9001"], blueprint.dig("reconciliation", "invoices").map { |invoice| invoice["qbo_id"] }
  end

  test "over the cap, the true-ups are reduced pro rata and sum to the cap" do
    charge_fee("60000.0") # cap 33,000 against 43,000 calculated

    report = sync!

    assert_equal [BigDecimal("15348.84"), BigDecimal("17651.16")],
      [trueup_for(@chief).amount, trueup_for(@principal).amount]
    assert_equal BigDecimal("33000"), report.mso_trueups.sum(:amount)
    assert_equal "33000.0", report.blueprint["total_trueup"]
    assert_equal "4651.16", trueup_for(@chief).blueprint["reduction"]
  end

  test "someone who out-earned their target gets no row" do
    pay(@chief, 25_000)

    report = sync!

    assert_nil trueup_for(@chief)
    assert_equal [garden3d_ledger(@principal).id], report.mso_trueups.pluck(:ledger_id)
  end

  test "a sync makes no QuickBooks call and no bill" do
    Quickbooks::Service::Bill.any_instance.expects(:create).never
    MsoTrueup.any_instance.expects(:sync_qbo_bill!).never

    assert_nil sync!.notification # build_mso_month makes any QuickBooks token request raise
  end

  # --- syncing again -------------------------------------------------------------

  test "syncing an unchanged month again changes nothing, and nets no true-up against itself" do
    sync!
    before = rows

    sync!

    assert_equal before, rows
    assert_equal "0.0", trueup_for(@chief).blueprint["already_earned"]
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
  end

  test "an acceptance survives a sync that leaves the amount alone, and is cleared by one that changes it" do
    sync!
    trueup_for(@chief).toggle_acceptance!
    pay(@principal, 1_000) # moves the principal's figure, not the chief's

    sync!

    assert trueup_for(@chief).accepted?
    assert_equal BigDecimal("22000"), trueup_for(@principal).amount

    pay(@chief, 500)
    sync!

    chief = trueup_for(@chief)
    assert_equal BigDecimal("19500"), chief.amount
    assert_not chief.accepted?, "they accepted a different number"
  end

  test "a fraction of a cent in what was earned does not clear an acceptance on every sync" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @chief)
    Mso::MonthlyRun.stubs(:already_earned).returns({})
    Mso::MonthlyRun.stubs(:already_earned).with(has_entry(contributor_id: @chief.id))
      .returns({ sanctuary_ledger.id => BigDecimal("179.8089646737429") })

    sync!
    assert_equal BigDecimal("19820.19"), trueup_for(@chief).amount, "20000 - 179.8089646737429, rounded DOWN"
    trueup_for(@chief).toggle_acceptance!

    sync!

    assert trueup_for(@chief).accepted?
    assert_equal BigDecimal("19820.19"), trueup_for(@chief).amount
  end

  test "once every true-up is accepted the month is settled: nothing changes, even when inputs move" do
    sync!
    trueup_for(@chief).toggle_acceptance!
    trueup_for(@principal).toggle_acceptance!
    before = rows
    generated_at = PeriodicReport.find(@report.id).blueprint["generated_at"]

    pay(@chief, 7_000)
    charge_fee("60000.0")
    Mso::MonthlyRun.expects(:compute).never
    report = sync!(today: TODAY + 30)

    assert_equal before, rows
    assert_equal generated_at, report.blueprint["generated_at"]
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
  end

  test "true-ups are out of sync when the month, computed now, would give different amounts" do
    sync!
    report = PeriodicReport.find(@report.id)
    assert_equal false, report.mso_trueups_out_of_sync?(today: TODAY)

    trueup_for(@chief).toggle_acceptance!
    trueup_for(@principal).toggle_acceptance!
    charge_fee("60000.0")

    assert_equal true, PeriodicReport.find(@report.id).mso_trueups_out_of_sync?(today: TODAY)
  end

  test "true-ups are out of sync when the month can no longer be computed" do
    sync!
    Mso::MonthlyRun.stubs(:compute).raises(Mso::MonthlyRun::Refused, "4100 does not reconcile")

    assert_equal true, PeriodicReport.find(@report.id).mso_trueups_out_of_sync?(today: TODAY)
  end

  test "a month with no true-ups is never out of sync, and is not computed" do
    Mso::MonthlyRun.expects(:compute).never

    assert_equal false, @report.mso_trueups_out_of_sync?(today: TODAY)
  end

  test "an executive no longer owed loses their row; everyone else's figure is still updated" do
    sync!
    chief_id = trueup_for(@chief).id
    pay(@chief, 25_000)
    pay(@principal, 1_000)

    report = sync!

    assert_nil report.notification
    assert_nil MsoTrueup.with_deleted.find_by(id: chief_id), "destroyed fully, as an obsolete profit share is"
    assert_equal BigDecimal("22000"), trueup_for(@principal).amount
  end

  test "someone taken off the month's roster loses their row" do
    sync!
    MsoRolePeriod.where(id: @chief_role.id).update_all(ended_at: Date.new(2093, 4, 30))

    report = sync!

    assert_nil report.notification
    assert_equal [garden3d_ledger(@principal).id], report.mso_trueups.pluck(:ledger_id)
  end

  test "an obsolete row whose QuickBooks bill is paid is skipped, not fatal" do
    sync!
    chief = trueup_for(@chief)
    pay(@chief, 25_000)
    pay(@principal, 1_000)
    MsoTrueup.any_instance.stubs(:detach_and_destroy_qbo_bill)
      .raises(SyncsAsQboBill::PaidQboBillError, "refusing to destroy QBO bill 55")

    report = sync!

    assert_nil report.notification
    assert MsoTrueup.find_by(id: chief.id), "the paid row is left for a person"
    assert_equal BigDecimal("20000"), chief.reload.amount
    assert_equal BigDecimal("22000"), trueup_for(@principal).amount, "and the rest of the month still updated"
    assert_equal "22000.0", report.blueprint["total_trueup"]
  end

  test "a soft-deleted row is restored as the same row, unaccepted when its amount changed" do
    sync!
    chief = trueup_for(@chief)
    chief.update_columns(accepted_at: Time.current)
    chief.destroy
    pay(@chief, 500)

    report = sync!

    assert_nil report.notification
    again = trueup_for(@chief)
    assert_equal chief.id, again.id
    assert_equal BigDecimal("19500"), again.amount
    assert_not again.accepted?
  end

  # --- a month that cannot be computed ---------------------------------------------

  CHECKS = {
    "the month has not ended" => [->(_) {}, /has not ended/, { today: Date.new(2093, 5, 31) }],
    "Sanctuary has no pass" => [
      lambda do |test|
        test.instance_variable_get(:@tracker).contributor_payouts.each(&:destroy_fully!)
        InvoiceTracker.where(invoice_pass_id: test.instance_variable_get(:@sanctuary_pass).id).delete_all
        InvoicePass.where(id: test.instance_variable_get(:@sanctuary_pass).id).delete_all
      end, /has no invoice pass/,
    ],
    "Sanctuary's pass is not complete" => [
      ->(test) { test.instance_variable_get(:@sanctuary_pass).update_columns(completed_at: nil) },
      /has not finished invoicing/,
    ],
    "Sanctuary's pass has no payouts" => [
      ->(test) { ContributorPayout.where(invoice_tracker_id: test.instance_variable_get(:@tracker).id).each(&:destroy) },
      /no contributor payouts/,
    ],
    "someone has two role periods" => [
      lambda do |test|
        MsoRolePeriod.new(contributor: test.instance_variable_get(:@chief), tier: :svp, title: "Second",
                          started_at: Date.new(2093, 1, 1)).save!(validate: false)
      end, /More than one MSO role period/,
    ],
    "a garden3d ledger is not QuickBooks-bound" => [
      ->(test) { test.garden3d_ledger(test.instance_variable_get(:@chief)).update!(mode: :legacy) },
      /not QuickBooks-bound/,
    ],
    "a founder true-up exists for someone on the roster" => [
      lambda do |test|
        Trueup.create!(
          invoice_pass: test.instance_variable_get(:@sanctuary_pass), amount: "4000", description: "founder true-up",
          ledger: Ledger.find_or_create_for(enterprise: test.instance_variable_get(:@sanctuary),
                                            contributor: test.instance_variable_get(:@principal)),
        )
      end, /already has a founder true-up/,
    ],
    "account 4100 does not reconcile" => [
      ->(test) { test.charge_fee("100000.0", account_total: "130000.0") }, /variance 30000\.0/,
    ],
  }.freeze

  CHECKS.each do |name, (break_it, message, opts)|
    test "when #{name}, existing true-ups are untouched and the reason is recorded" do
      sync!
      trueup_for(@chief).toggle_acceptance!
      before = rows
      pay(@principal, 1_000) # so a sync that got through would change something
      break_it.call(self)

      report = sync!(**(opts || {}))

      assert_equal before, rows
      assert report.notification.present?
      assert_match message, report.notification.params[:exception][:message]
      assert_equal ["generated_at"], report.blueprint.keys
    end
  end

  test "a month before MSO compensation began records the reason and writes nothing" do
    early = mso_report(InvoicePass::INTERCOMPANY_START - 1.month)

    report = sync!(early)

    assert_match(/starts in/, report.notification.params[:exception][:message])
    assert_equal 0, MsoTrueup.count
  end

  test "a sync that succeeds clears an earlier failure's notification" do
    @sanctuary_pass.update_columns(completed_at: nil)
    assert sync!.notification.present?

    @sanctuary_pass.update_columns(completed_at: Time.current)
    report = sync!

    assert_nil report.notification
    assert_equal 2, report.mso_trueups.count
  end

  # --- months do not leak into each other -------------------------------------------

  test "one month's true-up is that month's income, and does not reduce the next month's" do
    sync!
    assert_equal BigDecimal("20000"),
      Ledger::QualifyingIncome.for(ledger: garden3d_ledger(@chief), month: MONTH)

    june = Date.new(2093, 6, 1)
    june_sanctuary = sanctuary_pass(june)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "June Client #{SecureRandom.hex(3)}")
    june_tracker = InvoiceTracker.create!(invoice_pass: june_sanctuary, forecast_client: client,
                                          qbo_account: Enterprise.find(@sanctuary.id).qbo_account)
    { "ja" => 30_000, "jb" => 20_000, "jc" => 10_000 }.each do |tag, amount|
      pay(mso_person("earner-#{tag}"), amount, tracker: june_tracker)
    end
    attach_invoice(fee_tracker(garden3d_pass(june), @payer), qbo_id: "9002", total: "100000.0", balance: "0.0",
                                                             sent: true)
    fee_report(june, "100000.0")
    june_report = mso_report(june)

    report = sync!(june_report, today: Date.new(2093, 7, 10))

    assert_nil report.notification
    june_trueup = trueup_for(@chief, report: june_report)
    assert_equal "0.0", june_trueup.blueprint["already_earned"], "May's true-up is dated 31 May and is May's income"
    assert_equal BigDecimal("20000"), june_trueup.amount
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
  end
end
