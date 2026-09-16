# test/models/invoice_tracker_payouts_test.rb
require "test_helper"

# Exercises make_contributor_payouts! against real rows with the QBO invoice
# stubbed, so the split percentages can be asserted per billing model.
class InvoiceTrackerPayoutsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @pass = InvoicePass.find_or_create_by!(start_of_month: Date.new(2026, 8, 1)) { |ip| ip.data = {} }
    @client = ForecastClient.create!(forecast_id: 700_001, name: "Payout Split Client")
    @project = ForecastProject.create!(forecast_id: 700_001, client_id: @client.forecast_id, name: "Split Proj", code: "SPL-1", tags: ["200p/h"])

    @ic = ForecastPerson.create!(forecast_id: 700_001, email: "ic-split@example.com", data: {})
    @al_admin = AdminUser.create!(email: "al-split@example.com", password: "password123", password_confirmation: "password123")
    @al = ForecastPerson.create!(forecast_id: 700_002, email: @al_admin.email, data: {})
    @pl_admin = AdminUser.create!(email: "pl-split@example.com", password: "password123", password_confirmation: "password123")
    @pl = ForecastPerson.create!(forecast_id: 700_003, email: @pl_admin.email, data: {})
    @creator = AdminUser.create!(email: "creator-split@example.com", password: "password123", password_confirmation: "password123")
  end

  def build_tracker(model)
    pt = ProjectTracker.new(name: "Split Tracker #{model}", billing_model: model)
    pt.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: @project)
    AccountLeadPeriod.create!(project_tracker: pt, admin_user: @al_admin, started_at: Date.new(2026, 8, 1))
    ProjectLeadPeriod.create!(project_tracker: pt, admin_user: @pl_admin, started_at: Date.new(2026, 8, 1))
    pt
  end

  def build_invoice_tracker
    it = InvoiceTracker.create!(
      forecast_client: @client,
      invoice_pass: @pass,
      qbo_account: qbo_accounts(:one),
      blueprint: {
        "generated_at" => DateTime.now.to_s,
        "lines" => {
          "SPL-1 Split Proj (August 2026) IC [FP-700001]" => {
            "id" => "1",
            "forecast_project" => @project.forecast_id,
            "forecast_person" => @ic.forecast_id,
            "quantity" => 10.0,
            "unit_price" => 200.0,
          },
        },
      },
    )
    qbo_invoice = mock("qbo_invoice")
    qbo_invoice.stubs(:line_items).returns([{ "id" => "1", "amount" => 2000.0, "description" => "SPL-1 Split Proj (August 2026) IC [FP-700001]" }])
    qbo_invoice.stubs(:data).returns({})
    it.stubs(:qbo_invoice).returns(qbo_invoice)
    it
  end

  def amount_for(invoice_tracker, forecast_person)
    invoice_tracker.contributor_payouts.reload.find { |cp| cp.contributor.forecast_person == forecast_person }&.amount&.to_f
  end

  test "a new_deal_v2 tracker pays IC 54%, Account Lead 8%, Project Lead 5%" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)

    assert_in_delta 1080.0, amount_for(it, @ic), 0.01   # 2000 * 0.54
    assert_in_delta 160.0, amount_for(it, @al), 0.01    # 2000 * 0.08
    assert_in_delta 100.0, amount_for(it, @pl), 0.01    # 2000 * 0.05

    ic_cp = it.contributor_payouts.find { |cp| cp.contributor.forecast_person == @ic }
    assert_match(/54\.0%/, ic_cp.blueprint["IndividualContributor"].first["description_line"])
  end

  test "a new_deal_v1 tracker still pays IC 57%" do
    build_tracker("new_deal_v1")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)

    assert_in_delta 1140.0, amount_for(it, @ic), 0.01   # 2000 * 0.57
    assert_in_delta 160.0, amount_for(it, @al), 0.01
    assert_in_delta 100.0, amount_for(it, @pl), 0.01
  end

  test "a new_deal_v2 tracker pays lead surplus as Floats when the IC is below the ceiling" do
    build_tracker("new_deal_v2")
    @project.update!(notes: "#{@ic.email}:80p/h")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)

    # working 2000, IC 10 hrs * $80 = 800 → margin 0.60; surplus = (0.60 - 0.46) * 2000 = 280
    assert_in_delta 800.0, amount_for(it, @ic), 0.01
    lead_share = 42.0   # 280 * 0.15

    { @al => "AccountLeadSurplus", @pl => "ProjectLeadSurplus" }.each do |person, role|
      cp = it.contributor_payouts.reload.find { |c| c.contributor.forecast_person == person }
      entry = cp.blueprint[role]&.first
      assert entry.present?, "expected a #{role} entry for #{person.email}"
      # A BigDecimal here would round-trip through jsonb as the string "0.42e2".
      assert_kind_of Float, entry["amount"]
      assert_in_delta lead_share, entry["amount"], 0.001
    end

    assert_in_delta 160.0 + lead_share, amount_for(it, @al), 0.01
    assert_in_delta 100.0 + lead_share, amount_for(it, @pl), 0.01
  end

  test "a PercentageCommission on a new_deal_v2 tracker comes off the top" do
    pt = build_tracker("new_deal_v2")
    recipient_admin = AdminUser.create!(email: "comm-split@example.com", password: "password123", password_confirmation: "password123")
    recipient = ForecastPerson.create!(forecast_id: 700_004, email: recipient_admin.email, data: {})
    PercentageCommission.create!(project_tracker: pt, contributor: recipient.contributor, rate: 0.10)

    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)

    assert_in_delta 200.0, amount_for(it, recipient), 0.01   # 2000 * 0.10
    # working = 2000 - 200 = 1800
    assert_in_delta 144.0, amount_for(it, @al), 0.01         # 1800 * 0.08
    assert_in_delta 90.0, amount_for(it, @pl), 0.01          # 1800 * 0.05
    assert_in_delta 972.0, amount_for(it, @ic), 0.01         # 1800 * 0.54 — exactly the ceiling, so no surplus
  end

  test "description lines render the model's lead percentages" do
    build_tracker("new_deal_v2")
    it = build_invoice_tracker
    it.make_contributor_payouts!(@creator)
    al_cp = it.contributor_payouts.reload.find { |cp| cp.contributor.forecast_person == @al }
    pl_cp = it.contributor_payouts.find { |cp| cp.contributor.forecast_person == @pl }
    assert_match(/\* 8\.0% =/, al_cp.blueprint["AccountLead"].first["description_line"])
    assert_match(/\* 5\.0% =/, pl_cp.blueprint["ProjectLead"].first["description_line"])
  end
end
