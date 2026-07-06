require "test_helper"
require "rake"

class LedgersRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("ledgers:migrate_qbo_bound_zero_drift")
    Rake::Task["ledgers:migrate_qbo_bound_zero_drift"].reenable

    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.create!(name: "RakeMig-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "rm#{SecureRandom.hex(2)}", client_secret: "s", realm_id: "r#{SecureRandom.hex(2)}")
    @qbo_vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "v#{SecureRandom.hex(2)}", data: { "balance" => "0.0" })
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "rm#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    ContributorQboVendor.create!(contributor: @contributor, qbo_account: @qa, qbo_vendor: @qbo_vendor)
  end

  test "ready legacy ledger is auto-flipped to qbo_bound" do
    @ledger.update!(mode: :legacy)
    Rake::Task["ledgers:migrate_qbo_bound_zero_drift"].invoke
    assert @ledger.reload.qbo_bound?
  end

  test "blocked ledger stays legacy" do
    @ledger.update!(mode: :legacy)
    blocked = Ledgers::QboBoundMigrationCheck::Result.new(
      current_balance: 0, current_unsettled: 0, proposed_balance: 100, proposed_unsettled: 0,
      balance_delta: 100, unsettled_delta: 0,
      stacks_open_total: 100, qbo_vendor_balance: 0, qbo_diff: 100,
      qbo_match?: false, qbo_vendor_missing?: false,
      ready?: false, removed_neg_cas: [], removed_dias: [], dropped_paid_hosts: [], open_qbo_bills: [],
    )
    Ledgers::QboBoundMigrationCheck.stubs(:call).returns(blocked)

    Rake::Task["ledgers:migrate_qbo_bound_zero_drift"].invoke
    assert @ledger.reload.legacy?
  end
end
