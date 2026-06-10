require "test_helper"

class QboBillAccountMappingTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "MapTest-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "x", client_secret: "y", realm_id: "realm-#{SecureRandom.hex(4)}")
    @chart_account = QboChartAccount.create!(qbo_account: @qa, qbo_id: "77", name: "Contractors - Client Services", data: {})
  end

  test "valid entity-default mapping" do
    m = QboBillAccountMapping.new(
      enterprise: @enterprise,
      line_item_key: "trueup",
      qbo_chart_account_qbo_id: "77",
    )
    assert m.valid?, m.errors.full_messages.join(", ")
    assert_equal "Entity default", m.subject_label
  end

  test "rejects unknown line_item_key" do
    m = QboBillAccountMapping.new(enterprise: @enterprise, line_item_key: "nonsense", qbo_chart_account_qbo_id: "77")
    refute m.valid?
    assert m.errors[:line_item_key].any?
  end

  test "rejects a mapping whose chart account is missing from the mirror" do
    m = QboBillAccountMapping.new(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "NOPE")
    refute m.valid?
    assert_match(/not found/, m.errors[:qbo_chart_account_qbo_id].join)
  end

  test "rejects a mapping whose chart account is inactive" do
    @chart_account.update!(active: false)
    m = QboBillAccountMapping.new(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "77")
    refute m.valid?
    assert_match(/inactive/, m.errors[:qbo_chart_account_qbo_id].join)
  end

  test "rejects setting both contributor and project tracker" do
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "m#{SecureRandom.hex(2)}@x.com", data: {})
    contributor = Contributor.create!(forecast_person: fp)
    tracker = ProjectTracker.new(name: "PT-#{SecureRandom.hex(2)}")
    tracker.save!(validate: false)

    m = QboBillAccountMapping.new(
      enterprise: @enterprise, line_item_key: "trueup",
      contributor: contributor, project_tracker: tracker,
      qbo_chart_account_qbo_id: "77",
    )
    refute m.valid?
    assert m.errors[:base].any?
  end

  test "duplicate entity-default rows are rejected" do
    QboBillAccountMapping.create!(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "77")
    dup = QboBillAccountMapping.new(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "77")
    refute dup.valid?
  end

  test "chart_account returns the mirror row" do
    m = QboBillAccountMapping.create!(enterprise: @enterprise, line_item_key: "trueup", qbo_chart_account_qbo_id: "77")
    assert_equal @chart_account, m.chart_account
  end
end
