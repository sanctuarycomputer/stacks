require "test_helper"
require "rake"

class LedgersRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("ledgers:migrate_qbo_bound_zero_drift")
    Rake::Task["ledgers:migrate_qbo_bound_zero_drift"].reenable

    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "RakeMig-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "rm#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
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
      balance_delta: 100, unsettled_delta: 0, ready?: false, removed_neg_cas: [], removed_dias: [], dropped_paid_hosts: [], open_qbo_bills: [],
    )
    Ledgers::QboBoundMigrationCheck.stubs(:call).returns(blocked)

    Rake::Task["ledgers:migrate_qbo_bound_zero_drift"].invoke
    assert @ledger.reload.legacy?
  end
end
