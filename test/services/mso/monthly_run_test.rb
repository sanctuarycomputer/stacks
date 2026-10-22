require "test_helper"

# The computation and its checks. What is done with the answer is
# PeriodicReport#sync_mso_trueups! (test/models/periodic_report_mso_trueups_test.rb).
class Mso::MonthlyRunTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2093, 5, 1)
  TODAY = Date.new(2093, 6, 10)

  def setup
    build_mso_month(MONTH)
  end

  def teardown
    clear_enterprise_memos
  end

  def compute(month: MONTH, today: TODAY)
    Mso::MonthlyRun.compute(month: month, today: today)
  end

  def line_for(computation, contributor)
    computation.lines.find { |line| line.period.contributor_id == contributor.id }
  end

  def refused(**opts)
    assert_raises(Mso::MonthlyRun::Refused) { compute(**opts) }
  end

  test "it computes each executive's line and the month's figures, and writes nothing" do
    computation = nil
    assert_no_difference [-> { MsoTrueup.with_deleted.count }, -> { PeriodicReport.count }, -> { Ledger.count }] do
      computation = compute
    end

    assert_equal [BigDecimal("20000"), BigDecimal("23000")],
      [line_for(computation, @chief).amount, line_for(computation, @principal).amount]
    assert_equal garden3d_ledger(@chief), line_for(computation, @chief).ledger

    blueprint = computation.blueprint
    assert_equal "100000.0", blueprint["fee_income"]
    assert_equal "0.55", blueprint["cap_percentage"]
    assert_equal BigDecimal("55000"), BigDecimal(blueprint["cap"])
    assert_equal "20000.0", blueprint["benchmark_average"]
    assert_equal [3, 3, false], blueprint.values_at("configured_n", "counted", "small_sample")
    assert_equal %w[30000.0 20000.0 10000.0], blueprint["benchmark_members"].map { |member| member["amount"] }
    assert_equal [], blueprint["excluded_without_login"]
    assert_equal "43000.0", blueprint["total_calculated"]
    assert_equal "43000.0", blueprint["total_trueup"]
    assert_equal "0.0", blueprint.dig("reconciliation", "variance")
    assert_equal ["9001"], blueprint.dig("reconciliation", "invoices").map { |invoice| invoice["qbo_id"] }

    assert_equal(
      {
        "mso_role_period_id" => @principal_role.id, "contributor_id" => @principal.id,
        "tier" => "principal", "title" => "Founder", "multiplier" => "1.15",
        "already_earned" => "0.0", "earned_by_ledger" => {},
        "calculated" => "23000.0", "final" => "23000.0", "reduction" => "0.0", "trueup" => "23000.0"
      },
      line_for(computation, @principal).blueprint,
    )
    description = line_for(computation, @chief).description(MONTH)
    assert_match(/MSO true-up for May 2093/, description)
    assert_match(/Chief \(Operations\), 1\.0x/, description)
    assert_match(/\$20,000\.00/, description)
  end

  test "the benchmark average is kept unrounded" do
    pay(@top, "0.01") # the top three now total 60,000.01

    computation = compute

    assert_match(/\A20000\.003333333/, computation.blueprint["benchmark_average"])
    assert_match(/\A20000\.003333333/, line_for(computation, @chief).blueprint["calculated"])
    assert_equal BigDecimal("20000"), line_for(computation, @chief).amount
  end

  test "what a person already earned is netted across all their ledgers" do
    pay(@chief, 5_000)
    pay(@chief, 2_000, enterprise: enterprises(:one))

    computation = compute

    line = line_for(computation, @chief)
    assert_equal "7000.0", line.blueprint["already_earned"]
    assert_equal(
      {
        Ledger.find_by!(enterprise: @sanctuary, contributor: @chief).id.to_s => "5000.0",
        Ledger.find_by!(enterprise: enterprises(:one), contributor: @chief).id.to_s => "2000.0",
      },
      line.blueprint["earned_by_ledger"],
    )
    assert_equal BigDecimal("13000"), line.amount
    # The cap is a ceiling: one person's earnings change nobody else's true-up.
    assert_equal BigDecimal("23000"), line_for(computation, @principal).amount
  end

  test "someone who out-earned their target is owed nothing, and nothing is clawed back" do
    pay(@chief, 25_000)

    line = line_for(compute, @chief)

    assert_equal ["20000.0", "0.0"], line.blueprint.values_at("final", "trueup")
    assert_equal BigDecimal("0"), line.amount
  end

  test "over the cap, every line is reduced pro rata and the true-ups sum to the cap exactly" do
    charge_fee("60000.0") # cap 33,000 against 43,000 calculated

    computation = compute

    assert_equal BigDecimal("33000"), BigDecimal(computation.blueprint["cap"])
    assert_equal [BigDecimal("15348.84"), BigDecimal("17651.16")],
      [line_for(computation, @chief).amount, line_for(computation, @principal).amount]
    assert_equal "4651.16", line_for(computation, @chief).blueprint["reduction"]
    assert_equal "33000.0", computation.blueprint["total_trueup"]
  end

  # 20000 - 179.804 = 19820.196: down is .19, the nearest cent is .20. Paying
  # the nearest cent would pay more than `final - earned`, and over a full
  # roster more than the cap.
  test "a true-up is rounded DOWN to the cent, not to the nearest cent" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @chief)
    Mso::MonthlyRun.stubs(:already_earned).returns({})
    Mso::MonthlyRun.stubs(:already_earned).with(has_entry(contributor_id: @chief.id))
      .returns({ sanctuary_ledger.id => BigDecimal("179.804") })

    computation = compute

    assert_equal BigDecimal("19820.19"), line_for(computation, @chief).amount
    assert_equal "19820.19", line_for(computation, @chief).blueprint["trueup"]
    assert_equal "42820.19", computation.blueprint["total_trueup"]
  end

  test "a month with nobody on the roster has figures and no lines" do
    MsoRolePeriod.where(id: [@chief_role.id, @principal_role.id]).delete_all

    computation = compute

    assert_equal [], computation.lines
    assert_equal "20000.0", computation.blueprint["benchmark_average"]
    assert_equal "0.0", computation.blueprint["total_calculated"]
  end

  test "a month can be computed long after it ended" do
    assert_equal BigDecimal("20000"), line_for(compute(today: Date.new(2094, 2, 14)), @chief).amount
  end

  # --- the checks --------------------------------------------------------------

  test "it refuses a month that has not ended" do
    assert_match(/has not ended/, refused(today: Date.new(2093, 5, 31)).message)
    assert_nothing_raised { compute(today: Date.new(2093, 6, 1)) }
  end

  test "it refuses a month before MSO compensation began" do
    start = InvoicePass::INTERCOMPANY_START

    error = refused(month: start - 1.month, today: start + 1.year)

    assert_match(/starts in #{start.strftime('%B %Y')}/, error.message)
  end

  test "it refuses when Sanctuary has no pass for the month" do
    error = refused(month: Date.new(2093, 7, 1), today: Date.new(2093, 8, 10))

    assert_match(/Sanctuary Computer Inc has no invoice pass for July 2093/, error.message)
  end

  test "it refuses while Sanctuary's pass is not complete" do
    @sanctuary_pass.update_columns(completed_at: nil)

    assert_match(/has not finished invoicing/, refused.message)
  end

  test "it refuses when Sanctuary's pass has no contributor payouts yet" do
    ContributorPayout.where(invoice_tracker_id: @tracker.id).each(&:destroy)

    assert_match(/no contributor payouts/, refused.message)
  end

  test "two role periods for one person in the month are refused, naming them" do
    second = MsoRolePeriod.new(contributor: @chief, tier: :svp, title: "Second", started_at: Date.new(2093, 1, 1))
    second.save!(validate: false)

    error = refused

    assert_match(/contributor #{@chief.id}/, error.message)
    assert_match(/#{@chief_role.id}, #{second.id}/, error.message)
  end

  test "it refuses when an executive's garden3d ledger is not QuickBooks-bound" do
    garden3d_ledger(@chief).update!(mode: :legacy)

    assert_match(/Ledger #{garden3d_ledger(@chief).id}/, refused.message)
  end

  test "a founder true-up for someone on the roster is refused, naming it" do
    old_style = Trueup.create!(
      invoice_pass: @sanctuary_pass, amount: "4000", description: "founder true-up",
      ledger: Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @principal),
    )

    error = refused

    assert_match(/Trueup #{old_style.id} \(contributor #{@principal.id}/, error.message)
    assert_match(/delete it/, error.message)

    old_style.destroy
    assert_equal BigDecimal("23000"), line_for(compute, @principal).amount
  end

  test "account 4100 not reconciling with the fee invoices is refused, saying how to clear it" do
    charge_fee("100000.0", account_total: "130000.0") # 30,000 in account 4100 that no fee invoice explains

    error = refused

    assert_match(/variance 30000\.0/, error.message)
    assert_match(/attach/i, error.message)
    assert_match(/Managerial Services/, error.message)
  end

  test "a month with no management fee income is refused" do
    QboProfitAndLossReport.where(qbo_account_id: garden3d_qbo_account.id, starts_at: MONTH)
      .update_all(data: { cash: { rows: [] }, accrual: { rows: [["Total Income", "0"]] } })

    assert_match(/no management fee\s+income/, refused.message)
  end
end
