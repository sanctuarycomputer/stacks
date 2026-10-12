require "test_helper"

class Mso::BenchmarkTest < ActiveSupport::TestCase
  setup do
    @sanctuary = enterprises(:sanctuary)
    @month = Date.new(2091, 3, 1)
    @pass = InvoicePass.create!(start_of_month: @month, enterprise: @sanctuary, data: {})
    @admin = AdminUser.create!(email: "bm-admin-#{SecureRandom.hex(3)}@example.com",
                               password: "password12345", roles: ["admin"])
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "BM Client #{SecureRandom.hex(3)}")
    @tracker = InvoiceTracker.create!(invoice_pass: @pass, forecast_client: client,
                                      qbo_account: Enterprise.find(@sanctuary.id).qbo_account)
  end

  teardown do
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  def person(tag, login: true)
    email = "bm-#{tag}-#{SecureRandom.hex(3)}@example.com"
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    AdminUser.create!(email: email, password: "password12345") if login
    fp.contributor || Contributor.create!(forecast_person: fp)
  end

  # Payouts are saved without validation: this test is about who is in the
  # pool, not about ContributorPayout's own invoice-share rules.
  def pay(contributor, amount, enterprise: @sanctuary)
    ledger = Ledger.find_or_create_for(enterprise: enterprise, contributor: contributor)
    ContributorPayout.new(ledger: ledger, invoice_tracker: @tracker, created_by: @admin, amount: amount)
                     .save!(validate: false)
  end

  # A contributor with a login and `amount` of Sanctuary payout income in @month.
  def earner(tag, amount, login: true)
    person(tag, login: login).tap { |contributor| pay(contributor, amount) }
  end

  test "averages the top N earners" do
    a = earner("a", 30_000)
    b = earner("b", 20_000)
    c = earner("c", 10_000)
    earner("d", 5_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
    assert_kind_of BigDecimal, result.average
    assert_equal 3, result.configured_n
    assert_equal 3, result.counted
    assert_equal false, result.small_sample
    assert_equal [a.id, b.id, c.id], result.members.map { |m| m[:contributor_id] }
    assert_equal BigDecimal("30000"), result.members.first[:amount]
    assert_equal [], result.excluded_without_login
  end

  test "fewer earners than N averages over those present and flags a small sample" do
    earner("a", 30_000)
    earner("b", 10_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
    assert_equal 3, result.configured_n
    assert_equal 2, result.counted
    assert_equal true, result.small_sample
  end

  test "nobody earning gives a zero average, not a division error" do
    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("0"), result.average
    assert_equal 0, result.counted
    assert_equal true, result.small_sample
    assert_equal [], result.members
  end

  test "a top_n below one is rejected" do
    assert_raises(ArgumentError) { Mso::Benchmark.for_month(@month, top_n: 0) }
  end

  test "a payee with no login is left out, and reported when they would have ranked" do
    earner("a", 20_000)
    earner("b", 10_000)
    outsider = earner("outside-referrer", 21_024.90, login: false)

    result = Mso::Benchmark.for_month(@month, top_n: 2)

    assert_equal BigDecimal("15000"), result.average
    assert_equal 2, result.counted
    assert_equal [{ contributor_id: outsider.id, amount: BigDecimal("21024.9") }], result.excluded_without_login
  end

  test "a payee with no login who would not have ranked is not reported" do
    earner("a", 20_000)
    earner("b", 10_000)
    earner("small-contractor", 500, login: false)

    result = Mso::Benchmark.for_month(@month, top_n: 2)

    assert_equal [], result.excluded_without_login
  end

  test "with fewer than N counted, every payee with no login is reported" do
    earner("a", 20_000)
    contractor = earner("contractor", 500, login: false)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal 1, result.counted
    assert_equal [contractor.id], result.excluded_without_login.map { |m| m[:contributor_id] }
  end

  test "pay stubs count alongside payouts" do
    salaried = person("salaried")
    ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: salaried)
    cycle = PayCycle.create!(enterprise: @sanctuary, starts_at: @month, ends_at: @month.end_of_month)
    PayStub.create!(pay_cycle: cycle, ledger: ledger, amount: 12_000, blueprint: {
      "lines" => [{ "forecast_project" => "p", "hours" => 1, "rate" => 12_000, "amount" => 12_000, "description" => "x" }],
    })
    pay(salaried, 8_000)
    earner("a", 10_000)

    result = Mso::Benchmark.for_month(@month, top_n: 2)

    assert_equal salaried.id, result.members.first[:contributor_id]
    assert_equal BigDecimal("20000"), result.members.first[:amount]
    assert_equal BigDecimal("15000"), result.average
  end

  test "a payee with no login who ties the last counted member is reported" do
    earner("a", 20_000)
    earner("b", 10_000)
    tied = earner("tied-contractor", 10_000, login: false)

    result = Mso::Benchmark.for_month(@month, top_n: 2)

    assert_equal [tied.id], result.excluded_without_login.map { |m| m[:contributor_id] }
  end

  test "a recruiting fee paid as an adjustment counts as earnings" do
    recruiter = earner("recruiter", 10_000)
    ContributorAdjustment.create!(
      ledger: Ledger.find_by!(enterprise: @sanctuary, contributor: recruiter),
      qbo_account: Enterprise.find(@sanctuary.id).qbo_account,
      amount: 6_000, effective_on: @month + 14, description: "talent sourcing fee",
    )
    earner("a", 12_000)

    result = Mso::Benchmark.for_month(@month, top_n: 1)

    assert_equal [recruiter.id], result.members.map { |m| m[:contributor_id] }
    assert_equal BigDecimal("16000"), result.average
  end

  test "an old-style payment record does not reduce someone's earnings" do
    paid = earner("paid", 20_000)
    ContributorAdjustment.create!(
      ledger: Ledger.find_by!(enterprise: @sanctuary, contributor: paid),
      qbo_account: Enterprise.find(@sanctuary.id).qbo_account,
      amount: -20_000, effective_on: @month + 20, description: "Misc payment",
      skip_qbo_bound_negative_check: true,
    )

    result = Mso::Benchmark.for_month(@month, top_n: 1)

    assert_equal BigDecimal("20000"), result.average
  end

  test "a profit share counts as earnings" do
    sharer = earner("sharer", 10_000)
    report = PeriodicReport.create!(period_gradation: :quarter, period_starts_at: Date.new(2091, 1, 1),
                                    period_label: "Q1, 2091")
    ProfitShare.create!(periodic_report: report, blueprint: { "shares" => 1 }, amount: 500,
                        ledger: Ledger.find_by!(enterprise: @sanctuary, contributor: sharer))

    result = Mso::Benchmark.for_month(@month, top_n: 1)

    assert_equal BigDecimal("10500"), result.average
  end

  test "true-ups are not earnings and do not count" do
    earner("a", 20_000)
    earner("b", 10_000)
    topped_up = person("founder")
    Trueup.create!(ledger: Ledger.find_or_create_for(enterprise: @sanctuary, contributor: topped_up),
                   invoice_pass: @pass, amount: 20_000, description: "founder true-up")

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal 2, result.counted
    assert_equal BigDecimal("15000"), result.average
    refute_includes result.members.map { |m| m[:contributor_id] }, topped_up.id
  end

  test "a current MSO executive is left out of the pool" do
    exec = earner("exec", 90_000)
    MsoRolePeriod.create!(contributor: exec, tier: :chief, title: "Ops", started_at: Date.new(2091, 1, 1))
    earner("a", 20_000)
    earner("b", 10_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("15000"), result.average
    refute_includes result.members.map { |m| m[:contributor_id] }, exec.id
  end

  test "a former MSO executive is left out of the pool" do
    former = earner("former", 90_000)
    MsoRolePeriod.create!(contributor: former, tier: :chief, title: "Ops",
                          started_at: Date.new(2090, 1, 1), ended_at: Date.new(2090, 12, 31))
    earner("a", 20_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
  end

  test "an executive whose role starts after the month still counts for it" do
    future = earner("future", 30_000)
    MsoRolePeriod.create!(contributor: future, tier: :chief, title: "Ops", started_at: Date.new(2091, 6, 1))
    earner("a", 10_000)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
  end

  test "income on another enterprise's ledger does not count" do
    earner("a", 20_000)
    elsewhere = person("elsewhere")
    pay(elsewhere, 80_000, enterprise: enterprises(:garden3d))

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal BigDecimal("20000"), result.average
    assert_equal 1, result.counted
  end

  test "zero and negative earners are left out" do
    earner("a", 20_000)
    earner("zero", 0)
    earner("negative", -500)

    result = Mso::Benchmark.for_month(@month, top_n: 3)

    assert_equal 1, result.counted
    assert_equal BigDecimal("20000"), result.average
  end

  test "ties are broken by contributor id whatever order the pool arrives in" do
    first = earner("tie-1", 10_000)
    second = earner("tie-2", 10_000)
    lower, higher = [first, second].sort_by(&:id)
    ledgers = [higher, lower].map { |c| Ledger.find_by!(enterprise: @sanctuary, contributor: c) }
    Mso::Benchmark.any_instance.stubs(:pool).returns(ledgers)

    result = Mso::Benchmark.for_month(@month, top_n: 1)

    assert_equal [lower.id], result.members.map { |m| m[:contributor_id] }
  end

  test "top_n defaults to the System setting" do
    System.stubs(:mso_top_n).returns(1)
    earner("a", 30_000)
    earner("b", 10_000)

    result = Mso::Benchmark.for_month(@month)

    assert_equal 1, result.configured_n
    assert_equal BigDecimal("30000"), result.average
  end
end
