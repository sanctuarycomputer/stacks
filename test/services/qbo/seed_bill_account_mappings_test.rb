require "test_helper"

class Qbo::SeedBillAccountMappingsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "SeedTest-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "x", client_secret: "y", realm_id: "realm-#{SecureRandom.hex(4)}")

    # Mirror rows matching today's hard-coded targets.
    mk = ->(qbo_id, name, acct_num = nil) {
      QboChartAccount.create!(qbo_account: @qa, qbo_id: qbo_id, name: name, acct_num: acct_num, data: {})
    }
    @client_services = mk.call("1", "Contractors - Client Services")
    @marketing       = mk.call("2", "Contractors - Marketing Services")
    @bonuses         = mk.call("3", "Bonuses", "5710")
    @commissions     = mk.call("4", "Commissions", "6120")
    @profit_liab     = mk.call("5", "Accrued Profit Sharing", "2340")
    @facilities      = mk.call("6", "Facilities Management Salaries")
    @studio_acct     = mk.call("7", "Contractors - Design")
  end

  def seed!
    Qbo::SeedBillAccountMappings.new(@enterprise, sync_chart_accounts: false).call
  end

  def default_mapping(key)
    QboBillAccountMapping.find_by(
      enterprise: @enterprise, line_item_key: key,
      contributor_id: nil, project_tracker_id: nil,
    )
  end

  test "seeds entity defaults matching the legacy hard-coded routing" do
    seed!

    assert_equal "1", default_mapping("payout_individual_contributor").qbo_chart_account_qbo_id
    assert_equal "1", default_mapping("payout_account_lead_base").qbo_chart_account_qbo_id
    assert_equal "1", default_mapping("payout_project_lead_base").qbo_chart_account_qbo_id
    assert_equal "1", default_mapping("trueup").qbo_chart_account_qbo_id
    assert_equal "1", default_mapping("contributor_adjustment").qbo_chart_account_qbo_id
    assert_equal "3", default_mapping("payout_account_lead_surplus").qbo_chart_account_qbo_id
    assert_equal "3", default_mapping("payout_project_lead_surplus").qbo_chart_account_qbo_id
    assert_equal "4", default_mapping("payout_commission").qbo_chart_account_qbo_id
    assert_equal "5", default_mapping("profit_share").qbo_chart_account_qbo_id
    assert_equal "6", default_mapping("pay_stub").qbo_chart_account_qbo_id
  end

  test "profit_share falls back to the contractor default when acct 2340 is absent (legacy parity)" do
    @profit_liab.destroy!
    seed!
    assert_equal "1", default_mapping("profit_share").qbo_chart_account_qbo_id
  end

  test "is idempotent" do
    seed!
    before = QboBillAccountMapping.count
    result = seed!
    assert_equal before, QboBillAccountMapping.count
    assert_equal 0, result[:created]
  end

  test "skips (and reports) keys whose account is missing from the mirror" do
    @facilities.destroy!
    result = seed!
    assert_nil default_mapping("pay_stub")
    assert result[:skipped].any? { |s| s.include?("pay_stub") }
  end

  test "snapshots studio routing into contributor-level rows" do
    studio = Studio.create!(name: "DesignCo-#{SecureRandom.hex(2)}", accounting_prefix: "Design, Other", mini_name: "dc#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "s#{SecureRandom.hex(2)}@x.com", roles: [studio.name], data: {})
    contributor = Contributor.create!(forecast_person: fp)

    seed!

    row = QboBillAccountMapping.find_by(
      enterprise: @enterprise, line_item_key: "trueup", contributor: contributor,
    )
    assert_not_nil row, "expected a contributor-level studio snapshot row"
    assert_equal "7", row.qbo_chart_account_qbo_id, "first accounting_prefix entry wins (Contractors - Design)"
    assert_equal 5, QboBillAccountMapping.where(enterprise: @enterprise, contributor: contributor).count,
      "five contractor-services kinds snapshotted"
  end

  test "maps internal-client project trackers to Marketing Services" do
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Internal-#{SecureRandom.hex(2)}", data: {})
    EnterpriseForecastClient.create!(enterprise: @enterprise, forecast_client: fc)
    fproj = ForecastProject.new(forecast_id: rand(1..2_000_000_000), client_id: fc.forecast_id, data: {})
    fproj.save!(validate: false)
    tracker = ProjectTracker.new(name: "INT-#{SecureRandom.hex(2)}")
    tracker.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: tracker, forecast_project: fproj)

    seed!

    %w[payout_individual_contributor payout_account_lead_base payout_project_lead_base].each do |key|
      row = QboBillAccountMapping.find_by(enterprise: @enterprise, line_item_key: key, project_tracker: tracker)
      assert_not_nil row, "expected tracker-level #{key} mapping"
      assert_equal "2", row.qbo_chart_account_qbo_id
    end
  end
end
