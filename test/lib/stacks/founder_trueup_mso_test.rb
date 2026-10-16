require "test_helper"

class FounderTrueupMsoTest < ActiveSupport::TestCase
  include MsoFixtures

  JANUARY = Date.new(2091, 1, 1)
  FEBRUARY = Date.new(2091, 2, 1)

  def setup
    @sanctuary = enterprises(:sanctuary)
    email = Stacks::System.singleton_class::FOUNDER_EMAIL
    fp = ForecastPerson.find_by(email: email) ||
         ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    @founder = fp.contributor || Contributor.create!(forecast_person: fp)
    @founder_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @founder)
    @top_earner = mso_person("ft-top", login: false)
    garden3d_qbo_account
    InvoicePass.where(start_of_month: [JANUARY, FEBRUARY]).destroy_all
  end

  def teardown
    clear_enterprise_memos
  end

  # Sanctuary's pass for the month: the top earner made 5,000, the founder 1,000.
  def month_with_payouts(month)
    pass = InvoicePass.create!(start_of_month: month, enterprise: @sanctuary, data: {})
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "FT Client #{SecureRandom.hex(3)}")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client: client,
                                     qbo_account: Enterprise.find(@sanctuary.id).qbo_account)
    { @top_earner => 5_000, @founder => 1_000 }.each do |contributor, amount|
      ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: contributor)
      ContributorPayout.new(ledger: ledger, invoice_tracker: tracker, created_by: mso_admin, amount: amount)
                       .save!(validate: false)
    end
    pass
  end

  def founder_role(started_at)
    MsoRolePeriod.create!(contributor: @founder, tier: :principal, title: "Founder", started_at: started_at)
  end

  # February was paid through the MSO: a true-up for the founder.
  def february_trueup(role)
    mso_trueup(mso_report(FEBRUARY), role, garden3d_ledger(@founder), amount: "900")
  end

  def sync!(*months)
    Stacks::System.stubs(:founder_trueup_months).returns(months)
    Stacks::System.sync_founder_trueups!
  end

  test "without an MSO role the founder true-up is written as before" do
    pass = month_with_payouts(JANUARY)

    sync!(JANUARY)

    assert_equal BigDecimal("4000"), Trueup.find_by!(invoice_pass: pass, ledger: @founder_ledger).amount
  end

  test "from the month the founder holds an MSO role, no founder true-up is written" do
    january = month_with_payouts(JANUARY)
    # February has no Sanctuary pass at all: a skipped month must not need one.
    founder_role(FEBRUARY)

    assert_difference -> { Trueup.count }, 1 do
      sync!(JANUARY, FEBRUARY)
    end

    assert Trueup.exists?(invoice_pass: january, ledger: @founder_ledger), "the month before the role is untouched"
    assert_equal true, Stacks::System.founder_paid_by_mso?(@founder, FEBRUARY)
    assert_equal false, Stacks::System.founder_paid_by_mso?(@founder, JANUARY)
  end

  test "an existing founder true-up in an MSO month is not rewritten by the sync" do
    pass = month_with_payouts(FEBRUARY)
    existing = Trueup.create!(invoice_pass: pass, ledger: @founder_ledger, amount: "123.45", description: "earlier")
    founder_role(FEBRUARY)

    assert_no_difference -> { Trueup.with_deleted.count } do
      sync!(FEBRUARY)
    end

    assert_equal BigDecimal("123.45"), existing.reload.amount
  end

  test "moving the role period off a month that has an MSO true-up does not bring the founder true-up back" do
    month_with_payouts(FEBRUARY)
    role = founder_role(FEBRUARY)
    # However it happened: the roster row no longer covers the month, and
    # the true-up row is soft-deleted.
    february_trueup(role).destroy
    MsoRolePeriod.where(id: role.id).update_all(started_at: Date.new(2091, 3, 1))

    assert_equal true, Stacks::System.founder_paid_by_mso?(@founder, FEBRUARY),
      "a soft-deleted MSO true-up still marks the month"
    assert_no_difference -> { Trueup.with_deleted.count } do
      sync!(FEBRUARY)
    end
  end

  test "deleting a founder true-up deletes its QuickBooks bill, and a paid bill refuses the delete" do
    pass = month_with_payouts(JANUARY)
    trueup = Trueup.create!(invoice_pass: pass, ledger: @founder_ledger, amount: "4000", description: "x",
                            qbo_bill_id: "55")

    Trueup.any_instance.expects(:detach_and_destroy_qbo_bill).once
      .raises(SyncsAsQboBill::PaidQboBillError, "refusing to destroy QBO bill 55")
    assert_raises(SyncsAsQboBill::PaidQboBillError) { trueup.destroy }
    assert Trueup.find_by(id: trueup.id), "a refused delete leaves the row"

    Trueup.any_instance.expects(:detach_and_destroy_qbo_bill).once
    Trueup.find(trueup.id).destroy
    assert_nil Trueup.find_by(id: trueup.id)
  end

  # The 2025 garden3d trackers were moved off Sanctuary's passes onto their own
  # passes. The payouts on them still count toward the founder's month.
  test "payouts on another enterprise's pass for the month still count" do
    pass = month_with_payouts(JANUARY)
    g3d_pass = garden3d_pass(JANUARY)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "FT g3d #{SecureRandom.hex(3)}")
    tracker = InvoiceTracker.create!(invoice_pass: g3d_pass, forecast_client: client, qbo_account: garden3d_qbo_account)
    ContributorPayout.new(ledger: @founder_ledger, invoice_tracker: tracker, created_by: mso_admin, amount: 700)
                     .save!(validate: false)

    sync!(JANUARY)

    assert_equal BigDecimal("3300"), Trueup.find_by!(invoice_pass: pass, ledger: @founder_ledger).amount
  end
end
