require "test_helper"

class Stacks::TaskBuilder::Discoveries::PayCyclesTest < ActiveSupport::TestCase
  setup do
    @enterprise = Enterprise.create!(name: "CycleEnt-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "cycle#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @admin = AdminUser.create!(email: "cycleadmin#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
    @enterprise.admin_users << @admin
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
    @blueprint = { "lines" => [{ "forecast_project" => "fp-1", "hours" => 10, "rate" => 100, "amount" => 1000.0, "description" => "Test" }] }
  end

  test "unapproved cycle with a stub produces an approval task for the enterprise admins" do
    create_stub!

    task = tasks_for_cycle.first
    assert_equal 1, tasks_for_cycle.count
    assert_equal [@admin], task.owners
  end

  test "approved cycle produces no task" do
    create_stub!
    @cycle.toggle_approval!(by: @admin)

    assert_empty tasks_for_cycle
  end

  test "cycle with no stubs produces no task" do
    assert_empty tasks_for_cycle
  end

  # Regenerating after hours move out of the cycle soft-deletes the stub; the
  # emptied cycle has nothing left to approve.
  test "cycle whose only stub is soft-deleted produces no task" do
    create_stub!.destroy

    assert_empty tasks_for_cycle
  end

  private

  def create_stub!
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
  end

  def tasks_for_cycle
    Stacks::TaskBuilder::Discoveries::PayCycles.new(admin_fallback: [@admin]).tasks.select do |task|
      task.type == :pay_cycle_needs_approval && task.subject == @cycle
    end
  end
end
