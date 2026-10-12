require "test_helper"

class MsoRolePeriodRunGuardTest < ActiveSupport::TestCase
  include MsoFixtures

  MARCH = Date.new(2091, 3, 1)
  MAY = Date.new(2091, 5, 1)

  def setup
    garden3d_qbo_account
    @exec = mso_person("guard-exec")
    @role = mso_role(@exec, tier: :chief, started_at: Date.new(2091, 1, 1))
    ledger = garden3d_ledger(@exec)
    # March and May have been run with this role period; a superseded
    # snapshot counts as much as a current one.
    [MARCH, MAY].each do |month|
      mso_snapshot(garden3d_pass(month), lines: [mso_line(@role, ledger, trueup: "100.0")])
    end
    MsoSnapshot.joins(:invoice_pass).where(invoice_passes: { start_of_month: MARCH })
      .update_all(superseded_at: Time.current)
  end

  def teardown
    clear_enterprise_memos
  end

  test "a role period a run has used cannot be destroyed; one never used can" do
    assert_equal [MARCH, MAY], @role.months_run

    assert_equal false, @role.destroy
    assert_match(/March 2091/, @role.errors.full_messages.to_sentence)
    assert MsoRolePeriod.exists?(@role.id)

    unused = mso_role(mso_person("guard-unused"), started_at: Date.new(2091, 1, 1))
    assert unused.destroy
    assert_not MsoRolePeriod.exists?(unused.id)
  end

  test "its tier, person, start and end cannot be changed so as to alter a month already run" do
    period = -> { MsoRolePeriod.find(@role.id) }

    assert_not period.call.update(tier: :principal)
    assert_not period.call.update(contributor: mso_person("guard-other"))
    assert_not period.call.update(started_at: Date.new(2091, 4, 1)), "would drop March"
    assert_not period.call.update(ended_at: Date.new(2091, 4, 30)), "would drop May"

    record = period.call
    record.update(tier: :principal)
    assert_match(/end this period and start a new one/, record.errors[:tier].to_sentence)

    # What stays possible: ending it after the last month run, starting it
    # earlier, and renaming it.
    assert period.call.update(ended_at: Date.new(2091, 5, 31))
    assert period.call.update(started_at: Date.new(2090, 12, 1))
    assert period.call.update(title: "Operations and Finance")
    assert_equal "chief", period.call.tier
  end
end
