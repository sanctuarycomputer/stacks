require 'test_helper'

class StacksTaskTest < ActiveSupport::TestCase
  setup do
    @admin = AdminUser.create!(email: "st#{SecureRandom.hex(4)}@example.com",
                               password: 'password123', password_confirmation: 'password123',
                               roles: ['admin'])
    @enterprise = Enterprise.create!(name: "Enterprise #{SecureRandom.hex(4)}")
  end

  def recurring_adjustment!
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                email: "rla#{SecureRandom.hex(4)}@example.com", data: {})
    contributor = Contributor.create!(forecast_person: fp)
    ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: contributor)
    RecurringLedgerAdjustment.create!(ledger: ledger, amount: 250.0, cadence: 'monthly',
                                      next_due_on: Date.today + 7)
  end

  test 'subject_display_name for RecurringLedgerAdjustment includes the amount by default' do
    task = StacksTask.new(type: :auto_paused_recurring_on_qbo_bound,
                          subject: recurring_adjustment!, owners: [@admin])
    assert_includes task.subject_display_name, '$250.00'
    assert_includes task.subject_display_name, 'monthly'
  end

  test 'subject_display_name redacts the amount when redact_amounts is true' do
    task = StacksTask.new(type: :auto_paused_recurring_on_qbo_bound,
                          subject: recurring_adjustment!, owners: [@admin])
    redacted = task.subject_display_name(redact_amounts: true)
    refute_includes redacted, '$'
    assert_includes redacted, 'monthly'
    assert_includes redacted, 'recurring adjustment'
    assert_includes redacted, @enterprise.name
  end

  test 'subject_display_name for Reimbursement is generic when redacted' do
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                email: "rb@ex.co", data: {})
    contributor = Contributor.create!(forecast_person: fp)
    ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: contributor)
    reimbursement = Reimbursement.create!(ledger: ledger, description: 'Team dinner $840',
                                          amount: 840.0, receipts: 'receipt.pdf')
    task = StacksTask.new(type: :pending_acceptance, subject: reimbursement, owners: [@admin])
    assert_equal "Reimbursement ##{reimbursement.id}", task.subject_display_name(redact_amounts: true)
    assert_includes task.subject_display_name, 'Team dinner' # default unchanged
  end

  test 'redact_amounts leaves non-monetary subjects untouched' do
    task = StacksTask.new(type: :missing_skill_tree, subject: @admin, owners: [@admin])
    assert_equal task.subject_display_name, task.subject_display_name(redact_amounts: true)
    assert_equal @admin.email, task.subject_display_name
  end
end
