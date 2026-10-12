require "test_helper"

class Ledger::MsoTrueupLedgerTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 5, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("ledger-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(@role, @ledger, trueup: "1500.0")], collected: true)
  end

  def teardown
    clear_enterprise_memos
  end

  def fresh_ledger
    Ledger.find(@ledger.id)
  end

  # Two months starting at MONTH; without the overrides an empty ledger's
  # walk stops two months from today and never reaches 2090.
  def grouped(ledger, **opts)
    ledger.items_grouped_by_month(MONTH, MONTH + 2.months, **opts)
  end

  def month_of(result)
    result[:by_month].find { |period, _| period.starts_at == MONTH }&.last
  end

  test "an unaccepted true-up is unsettled, and an accepted, collected one is balance" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1500")

    assert_equal 1500.0, fresh_ledger.unsettled.to_f
    assert_equal 0.0, fresh_ledger.balance.to_f

    trueup.toggle_acceptance!

    assert_equal 0.0, fresh_ledger.unsettled.to_f
    assert_equal 1500.0, fresh_ledger.balance.to_f
  end

  test "include_mso_trueups: false leaves it out of the balance, the unsettled total and the month" do
    mso_trueup(@snapshot, @role, @ledger, amount: "1500")

    assert_equal 0.0, fresh_ledger.unsettled(include_mso_trueups: false).to_f
    assert_equal 0.0, fresh_ledger.balance(include_mso_trueups: false).to_f
    hidden = month_of(grouped(fresh_ledger, include_mso_trueups: false))
    assert_equal [], hidden[:items]
    assert_equal 0, hidden[:total_income]
  end

  test "it is listed in its pass month and counts toward that month's income" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1500")

    month = month_of(grouped(fresh_ledger))

    assert_equal [trueup], month[:items]
    assert_equal 1500.0, month[:total_income]
  end

  test "a soft-deleted true-up is still listed for the strikethrough, but is in no total" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1500")
    trueup.destroy

    month = month_of(grouped(fresh_ledger))

    assert_equal [trueup.id], month[:items].map(&:id)
    assert_equal 0.0, fresh_ledger.unsettled.to_f
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: @ledger, month: MONTH)
  end

  test "it is qualifying income, and excluding: takes it back out" do
    trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1500")

    assert_equal BigDecimal("1500"), Ledger::QualifyingIncome.for(ledger: @ledger, month: MONTH)
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: @ledger, month: MONTH, excluding: [trueup])
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: @ledger, month: MONTH + 1.month)
  end

  test "no kind of true-up is benchmark income" do
    assert_includes Ledger::QualifyingIncome::KLASSES, MsoTrueup
    assert_not_includes Mso::Benchmark::KLASSES, MsoTrueup
    assert_not_includes Mso::Benchmark::KLASSES, Trueup
    assert_includes Mso::Benchmark::KLASSES, ContributorPayout
  end

  test "before the table exists, the ledger works and never queries it" do
    MsoTrueup.stubs(:schema_ready?).returns(false)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    ledger = fresh_ledger
    assert_equal 0.0, ledger.balance.to_f
    assert_equal 0.0, ledger.unsettled.to_f
    assert_equal [], month_of(grouped(ledger))[:items]
    assert_equal BigDecimal("0"), Ledger::QualifyingIncome.for(ledger: ledger, month: MONTH)

    assert_empty statements.grep(/mso_trueups/)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
