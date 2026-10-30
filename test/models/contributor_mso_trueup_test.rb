require "test_helper"

class ContributorMsoTrueupTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 6, 1)

  def setup
    garden3d_qbo_account
    fee_collected(MONTH)
    @exec = mso_person("walk-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @report = mso_report(MONTH)
    @period = Stacks::Period.new("June 2090", MONTH, MONTH.end_of_month)
  end

  def teardown
    clear_enterprise_memos
  end

  def fresh
    Contributor.find(@exec.id)
  end

  # The window Contributor#elevated_service_for_month uses (contributor.rb:584).
  def walk(contributor = fresh, **opts)
    contributor.all_items_grouped_by_month(false, MONTH, MONTH.end_of_month + 1.day, **opts)
  end

  def month_of(result)
    result[:by_month].find { |period, _| period.starts_at == MONTH }&.last
  end

  # A Sanctuary payout in the same month, so the walk has two kinds of item to sort.
  def sanctuary_payout(amount)
    sanctuary = enterprises(:sanctuary)
    pass = sanctuary_pass(MONTH)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Walk Client #{SecureRandom.hex(3)}")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client: client,
                                     qbo_account: Enterprise.find(sanctuary.id).qbo_account)
    payout = ContributorPayout.new(ledger: Ledger.find_or_create_for(enterprise: sanctuary, contributor: @exec),
                                   invoice_tracker: tracker, created_by: mso_admin, amount: amount)
    payout.save!(validate: false)
    payout
  end

  test "the walk lists an MSO true-up beside other items without failing to sort them" do
    trueup = mso_trueup(@report, @role, @ledger, amount: "9500")
    payout = sanctuary_payout(200)

    month = month_of(walk)

    assert_equal [trueup, payout].map { |i| [i.class, i.id] }.sort_by(&:to_s),
      month[:items].map { |i| [i.class, i.id] }.sort_by(&:to_s)
    assert_includes fresh.mso_trueups, trueup
  end

  test "an MSO true-up counts toward the month's income and so toward elevated service" do
    mso_trueup(@report, @role, @ledger, amount: "9500")

    month = month_of(walk)

    assert_equal BigDecimal("9500"), month[:total_income]
    assert_equal true, month[:elevated_service]
  end

  test "the bulk elevated-service query counts it too" do
    mso_trueup(@report, @role, @ledger, amount: "9500")
    login = login_for(@exec)

    ids = Contributor.elevated_service_admin_user_ids([@period], [@exec.forecast_person_id])

    assert_includes ids, login.id
  end

  test "the bulk elevated-service query ignores a soft-deleted true-up" do
    mso_trueup(@report, @role, @ledger, amount: "9500").destroy
    login = login_for(@exec)

    ids = Contributor.elevated_service_admin_user_ids([@period], [@exec.forecast_person_id])

    assert_not_includes ids, login.id
  end

  test "profit-share elevated service counts an MSO true-up only in a manually included month" do
    trueup = mso_trueup(@report, @role, @ledger, amount: "9500")
    report = PeriodicReport.new
    report.stubs(:period).returns(Stacks::Period.new("Q2 2090", Date.new(2090, 4, 1), Date.new(2090, 6, 30), :quarter))

    # The true-up sits on a garden3d ledger, which the automatic rule leaves out.
    result = report.profit_share_elevated_service_by_month(fresh, { @period => { items: [trueup] } })
    assert_equal({ @period => false }, result)

    ProfitShareManualInclusionPeriod.create!(contributor: @exec, started_at: @period.starts_at.beginning_of_month, note: "test")
    # A fresh report: a report loads its quarter's inclusions once.
    report = PeriodicReport.new
    report.stubs(:period).returns(Stacks::Period.new("Q2 2090", Date.new(2090, 4, 1), Date.new(2090, 6, 30), :quarter))
    result = report.profit_share_elevated_service_by_month(fresh, { @period => { items: [trueup] } })
    assert_equal({ @period => true }, result)
  end

  # Decisions 29: the dashboard every logged-in user can open shows this
  # figure. It must not move when executives' true-ups are written.
  test "the company-wide balance on the dashboard leaves MSO true-ups out" do
    past_report = mso_report(Date.new(2019, 2, 1))
    before = Contributor.aggregated_new_deal_balance
    mso_trueup(past_report, @role, @ledger, amount: "700", accepted: true)
    mso_trueup(@report, @role, @ledger, amount: "9500")

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end
    after = Contributor.aggregated_new_deal_balance

    assert_empty statements.grep(/mso_trueups/)
    assert_in_delta before[:balance].to_f, after[:balance].to_f, 0.001
    assert_in_delta before[:unsettled].to_f, after[:unsettled].to_f, 0.001
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
