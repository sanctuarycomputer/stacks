# test/services/invoice_payouts/build_test.rb
require "test_helper"

class InvoicePayoutsBuildTest < ActiveSupport::TestCase
  include PayoutFixtures

  setup { setup_payout_people }

  def payee(build, person)
    build.payees.find { |p| p.forecast_person == person }
  end

  test "base shares for a v2 line, with nothing written" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])

    assert_no_difference ["ContributorPayout.count", "Contributor.count", "Ledger.count"] do
      build = InvoicePayouts::Build.new(it)
      assert_in_delta 5400.0, payee(build, @ic).amount, 0.001
      assert_in_delta 800.0, payee(build, @al).amount, 0.001
      assert_in_delta 500.0, payee(build, @pl).amount, 0.001
      line = build.lines.first
      assert_in_delta 10_000.0, line.billed, 0.001
      assert_equal %w[AccountLead ProjectLead IndividualContributor], line.entries.map(&:role)
      assert_equal "- 100.0 hrs * $100.00 p/h * 54.0% = $5,400.00", payee(build, @ic).blueprint["IndividualContributor"].first["description_line"]
      assert_equal %w[AccountLead ProjectLead IndividualContributor Commission], payee(build, @ic).blueprint.keys
      assert_kind_of Float, payee(build, @ic).blueprint["IndividualContributor"].first["amount"]
    end
  end

  test "a rate override is flagged and its surplus goes to both leads" do
    build_tracker("new_deal_v1")
    @project.update!(notes: "#{@ic.email}:20p/h")
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    build = InvoicePayouts::Build.new(it)

    ic_entry = build.lines.first.entries.find { |e| e.role == "IndividualContributor" }
    assert ic_entry.rate_override
    assert_in_delta 2000.0, ic_entry.amount, 0.001
    # margin 0.80, threshold 0.43 → surplus 3700 → 555 to each lead
    assert_in_delta 800.0 + 555.0, payee(build, @al).amount, 0.001
    assert_in_delta 500.0 + 555.0, payee(build, @pl).amount, 0.001
    assert_equal 1, payee(build, @al).blueprint["AccountLeadSurplus"].length
    assert_kind_of Float, payee(build, @al).blueprint["AccountLeadSurplus"].first["amount"]
    assert_includes build.lines.first.entries.map(&:role), "ProjectLeadSurplus"
  end

  test "a full-time lead is listed but not paid, base or surplus" do
    build_tracker("new_deal_v1")
    @project.update!(notes: "#{@ic.email}:20p/h")
    FullTimePeriod.create!(admin_user: @al_admin, started_at: Date.new(2020, 1, 1), contributor_type: :five_day, expected_utilization: 0.8)
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    build = InvoicePayouts::Build.new(it)

    assert_not payee(build, @al).payable
    assert_not build.paid?(@al)
    assert_not_includes build.paid_payees.map(&:forecast_person), @al
    assert_nil payee(build, @al).blueprint["AccountLeadSurplus"]
    assert_in_delta 500.0 + 555.0, payee(build, @pl).amount, 0.001
  end

  test "commission to a payable recipient is recorded against its line" do
    pt = build_tracker("new_deal_v2")
    recipient = ForecastPerson.create!(forecast_id: 710_004, email: "comm-guard@example.com", data: {})
    recipient.ensure_contributor_exists!
    PercentageCommission.create!(project_tracker: pt, contributor: recipient.reload.contributor, rate: 0.10)
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    build = InvoicePayouts::Build.new(it)

    assert_in_delta 1000.0, build.paid_commissions_by_line["1"], 0.001
    assert_in_delta 9000.0, build.lines.first.working_amount, 0.001
    assert_in_delta 1000.0, payee(build, recipient).commission_amount, 0.001
    assert_in_delta 4860.0, payee(build, @ic).amount, 0.001 # 9000 * 0.54
  end

  # The one case where a line's commission_total (everything deducted) and the
  # commissions actually paid differ: surplus is then priced on the full line.
  test "commission owed to a salaried recipient is deducted but not paid" do
    pt = build_tracker("new_deal_v2")
    recipient_admin = AdminUser.create!(email: "comm-salaried-guard@example.com", password: "password123", password_confirmation: "password123")
    recipient = ForecastPerson.create!(forecast_id: 710_006, email: recipient_admin.email, data: {})
    recipient.ensure_contributor_exists!
    FullTimePeriod.create!(admin_user: recipient_admin, started_at: Date.new(2020, 1, 1), contributor_type: :five_day, expected_utilization: 0.8)
    PercentageCommission.create!(project_tracker: pt, contributor: recipient.reload.contributor, rate: 0.10)
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    build = InvoicePayouts::Build.new(it)

    assert_empty build.paid_commissions_by_line
    assert_in_delta 9000.0, build.lines.first.working_amount, 0.001
    assert_in_delta 4860.0, payee(build, @ic).amount, 0.001
    # surplus priced on 10,000: margin 0.514 - 0.46 = 540 → 81 to each lead
    assert_in_delta 720.0 + 81.0, payee(build, @al).amount, 0.001
    assert_in_delta 450.0 + 81.0, payee(build, @pl).amount, 0.001
    assert_not build.paid?(recipient)
  end

  test "zero or multiple project trackers for a client project raises as generation does" do
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    err = assert_raises(RuntimeError) { InvoicePayouts::Build.new(it).lines }
    assert_match(/No project trackers found/, err.message)
  end

  test "retained_orphans are existing payouts generation cannot remove" do
    build_tracker("new_deal_v1")
    it = build_invoice_tracker([{ id: "1", person: @ic, hours: 100.0, rate: 100.0 }])
    stranger = ForecastPerson.create!(forecast_id: 710_009, email: "gone-guard@example.com", data: {})
    stranger.ensure_contributor_exists!
    ledger = Ledger.find_or_create_for(enterprise: @client.billing_enterprise, contributor: stranger.reload.contributor)
    paid = ContributorPayout.new(invoice_tracker: it, ledger: ledger, amount: 3000.0, blueprint: {}, created_by: @creator)
    paid.skip_seventy_percent_check = true
    paid.save!

    bill = mock("qbo_bill")
    bill.stubs(:has_payments?).returns(true)
    ContributorPayout.any_instance.stubs(:qbo_bill).returns(bill)
    assert_equal [paid], InvoicePayouts::Build.new(it.reload).retained_orphans

    bill.stubs(:has_payments?).returns(false)
    assert_empty InvoicePayouts::Build.new(it.reload).retained_orphans
  end
end
