require "test_helper"

class Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigrationTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.create!(name: "DiscEnt-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(
      enterprise: @enterprise,
      client_id: "test_client",
      client_secret: "test_secret",
      realm_id: "rake#{SecureRandom.hex(4)}",
    )
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "disc#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    # New ledgers default to qbo_bound; pin the fixture to legacy so the
    # discovery has a candidate to surface.
    @ledger.update!(mode: :legacy)
    @admin = AdminUser.create!(email: "ldisc#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
  end

  test "legacy ledger with payable activity yields a migration task" do
    ContributorAdjustment.create!(ledger: @ledger, qbo_account: @qa, amount: 100, effective_on: Date.today)
    discovery = Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration.new(admin_fallback: [@admin])
    tasks = discovery.tasks
    assert tasks.any? { |t| t[:subject] == @ledger && t[:type] == :legacy_ledger_needs_qbo_migration }
  end

  test "qbo_bound ledger yields no task" do
    ContributorAdjustment.create!(ledger: @ledger, qbo_account: @qa, amount: 100, effective_on: Date.today)
    @ledger.update!(mode: :qbo_bound)
    discovery = Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration.new(admin_fallback: [@admin])
    tasks = discovery.tasks
    refute tasks.any? { |t| t[:subject] == @ledger }
  end

  test "legacy ledger without activity yields no task" do
    discovery = Stacks::TaskBuilder::Discoveries::LegacyLedgersPendingQboMigration.new(admin_fallback: [@admin])
    tasks = discovery.tasks
    refute tasks.any? { |t| t[:subject] == @ledger }
  end
end
