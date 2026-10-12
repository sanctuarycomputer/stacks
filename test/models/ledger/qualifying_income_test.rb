require "test_helper"

class Ledger::QualifyingIncomeTest < ActiveSupport::TestCase
  setup do
    @sanctuary = enterprises(:sanctuary)
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                email: "qi-#{SecureRandom.hex(3)}@example.com", data: {})
    @contributor = fp.contributor || Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @contributor)
    @admin = AdminUser.create!(email: "qi-admin-#{SecureRandom.hex(3)}@example.com",
                               password: "password12345", roles: ["admin"])
    @march = Date.new(2090, 3, 1)
    @march_pass = InvoicePass.create!(start_of_month: @march, enterprise: @sanctuary, data: {})
    @april_pass = InvoicePass.create!(start_of_month: Date.new(2090, 4, 1), enterprise: @sanctuary, data: {})
  end

  teardown do
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  def trueup(pass, amount)
    Trueup.create!(ledger: @ledger, invoice_pass: pass, amount: amount, description: "test trueup")
  end

  def payout(pass, amount)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "QI Client #{SecureRandom.hex(3)}")
    tracker = InvoiceTracker.create!(
      invoice_pass: pass,
      forecast_client: client,
      qbo_account: Enterprise.find(@sanctuary.id).qbo_account,
      # A blueprint gives the tracker a non-zero total, without which every
      # payout trips ContributorPayout's 70%-of-invoice validation.
      blueprint: { "lines" => { "Line" => { "quantity" => 100, "unit_price" => 1000 } } },
    )
    ContributorPayout.create!(ledger: @ledger, invoice_tracker: tracker, created_by: @admin, amount: amount)
  end

  def pay_stub(ends_at, amount)
    cycle = PayCycle.create!(enterprise: @sanctuary, starts_at: ends_at.beginning_of_month, ends_at: ends_at)
    PayStub.create!(pay_cycle: cycle, ledger: @ledger, amount: amount, blueprint: {
      "lines" => [{ "forecast_project" => "p", "hours" => 1, "rate" => amount, "amount" => amount, "description" => "x" }],
    })
  end

  def income(**opts)
    Ledger::QualifyingIncome.for(ledger: @ledger, month: @march, **opts)
  end

  test "an empty month is zero, as a BigDecimal" do
    assert_equal BigDecimal("0"), income
    assert_kind_of BigDecimal, income
  end

  test "sums true-ups, payouts and pay stubs that fall in the month" do
    trueup(@march_pass, "1000.25")
    payout(@march_pass, "2500.50")
    pay_stub(Date.new(2090, 3, 31), 900)

    assert_equal BigDecimal("4400.75"), income
    assert_kind_of BigDecimal, income
  end

  test "any date within the month selects that month" do
    trueup(@march_pass, "1000")
    assert_equal BigDecimal("1000"),
      Ledger::QualifyingIncome.for(ledger: @ledger, month: Date.new(2090, 3, 19))
  end

  test "rows from other months are left out" do
    trueup(@march_pass, "1000")
    trueup(@april_pass, "9999")
    payout(@april_pass, "500")
    pay_stub(Date.new(2090, 4, 30), 700)

    assert_equal BigDecimal("1000"), income
  end

  test "a soft-deleted true-up is not income" do
    trueup(@march_pass, "1000")
    trueup(@march_pass, "10300").destroy

    assert_equal BigDecimal("1000"), income
  end

  test "a soft-deleted payout is not income" do
    payout(@march_pass, "1000")
    payout(@march_pass, "10300").destroy

    assert_equal BigDecimal("1000"), income
  end

  test "a soft-deleted pay stub is not income" do
    trueup(@march_pass, "1000")
    pay_stub(Date.new(2090, 3, 31), 900).destroy

    assert_equal BigDecimal("1000"), income
  end

  test "differs from the ledger page's total_income by exactly the soft-deleted rows" do
    trueup(@march_pass, "1000")
    trueup(@march_pass, "10300").destroy

    # items_grouped_by_month(start, end) -> { by_month: { Stacks::Period => { total_income: Float } } }
    # Period generation stops before the month preceding the end date, so ask for a
    # later end date and read only March's bucket.
    grouped = @ledger.items_grouped_by_month(@march, @march.end_of_month + 2.months)
    display_total = grouped[:by_month].sum { |period, bucket| period.starts_at == @march ? bucket[:total_income] : 0 }

    assert_in_delta 11_300.0, display_total, 0.001, "the ledger page counts the deleted row, by design"
    assert_equal BigDecimal("1000"), income
  end

  test "another contributor's ledger is not counted" do
    other_fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                      email: "qi-other-#{SecureRandom.hex(3)}@example.com", data: {})
    other = other_fp.contributor || Contributor.create!(forecast_person: other_fp)
    other_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: other)
    Trueup.create!(ledger: other_ledger, invoice_pass: @march_pass, amount: 7777, description: "other")
    trueup(@march_pass, "1000")

    assert_equal BigDecimal("1000"), income
  end

  test "excluded records are left out, matched by class and id" do
    trueup(@march_pass, "1000")
    dropped = trueup(@march_pass, "400")

    assert_equal BigDecimal("1000"), income(excluding: [dropped])
    assert_equal BigDecimal("1400"), income(excluding: [])
  end

  test "exclusion matches on class as well as id" do
    kept = payout(@march_pass, "2500")
    # A true-up that shares the payout's id must not drag the payout out with it.
    same_id = Trueup.new(ledger: @ledger, invoice_pass: @march_pass, amount: 400, description: "same id")
    same_id.id = kept.id
    same_id.save!

    assert_equal BigDecimal("2500"), income(excluding: [same_id])
    assert_equal BigDecimal("400"), income(excluding: [kept])
  end

  test "naming a class twice does not count it twice" do
    trueup(@march_pass, "1000")

    assert_equal BigDecimal("1000"), income(klasses: [Trueup, Trueup])
  end

  test "the first and last day of the month both count" do
    pay_stub(Date.new(2090, 3, 31), 300)
    payout(@march_pass, "200") # effective on the 1st, its pass's start_of_month

    assert_equal BigDecimal("500"), income
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: @ledger, month: Date.new(2090, 2, 28))
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: @ledger, month: Date.new(2090, 4, 1))
  end

  def sanctuary_qbo_account
    Enterprise.find(@sanctuary.id).qbo_account
  end

  test "a positive adjustment, such as a recruiting fee, is compensation" do
    trueup(@march_pass, "1000")
    ContributorAdjustment.create!(ledger: @ledger, qbo_account: sanctuary_qbo_account,
                                  amount: 6000, effective_on: Date.new(2090, 3, 30), description: "recruiting fee")

    assert_equal BigDecimal("7000"), income
  end

  test "a negative adjustment is a record of money paid out, not negative income" do
    trueup(@march_pass, "1000")
    # Old-style ledgers mirrored each QuickBooks payment as a negative adjustment.
    ContributorAdjustment.create!(ledger: @ledger, qbo_account: sanctuary_qbo_account,
                                  amount: -5000, effective_on: Date.new(2090, 3, 15),
                                  description: "Misc payment", skip_qbo_bound_negative_check: true)

    assert_equal BigDecimal("1000"), income
  end

  test "an adjustment dated in another month is left out" do
    ContributorAdjustment.create!(ledger: @ledger, qbo_account: sanctuary_qbo_account,
                                  amount: 6000, effective_on: Date.new(2090, 4, 1))

    assert_equal BigDecimal("0"), income
  end

  test "a profit share counts in the month its period ends" do
    report = PeriodicReport.create!(period_gradation: :quarter, period_starts_at: Date.new(2090, 1, 1),
                                    period_label: "Q1, 2090")
    ProfitShare.create!(periodic_report: report, ledger: @ledger, amount: "272.46", blueprint: { "shares" => 1 })

    assert_equal BigDecimal("272.46"), income
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: @ledger, month: Date.new(2090, 2, 1))
  end

  test "a Deel invoice adjustment is not something that can be counted" do
    assert_raises(ArgumentError) { income(klasses: [DeelInvoiceAdjustment]) }
  end

  test "a reimbursement is not compensation" do
    trueup(@march_pass, "1000")
    Reimbursement.create!(ledger: @ledger, amount: 250, description: "taxi", receipts: "")

    assert_equal BigDecimal("1000"), income
  end

  test "klasses narrows which kinds of row count" do
    trueup(@march_pass, "1000")
    payout(@march_pass, "2500")

    assert_equal BigDecimal("2500"), income(klasses: [ContributorPayout, PayStub])
    assert_equal BigDecimal("1000"), income(klasses: [Trueup])
    assert_equal BigDecimal("3500"), income
  end

  test "an unknown class is rejected" do
    assert_raises(ArgumentError) { income(klasses: [Reimbursement]) }
  end
end
