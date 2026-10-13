require "test_helper"

class Stacks::TaskBuilder::Discoveries::UnacceptedMsoTrueupsTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 10, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("nag-exec")
    @ledger = garden3d_ledger(@exec)
    @role = mso_role(@exec)
    @snapshot = mso_snapshot(@pass, lines: [mso_line(@role, @ledger, trueup: "1000.0")])
    @trueup = mso_trueup(@snapshot, @role, @ledger, amount: "1000")
  end

  def teardown
    clear_enterprise_memos
  end

  def tasks
    Stacks::TaskBuilder::Discoveries::UnacceptedMsoTrueups.new(admin_fallback: [mso_admin]).tasks
  end

  test "an unaccepted true-up is one task for its executive, linking to their garden3d ledger" do
    mine = tasks.select { |task| task.subject == @exec }

    assert_equal 1, mine.size
    assert_equal :unaccepted_mso_trueup, mine.first.type
    assert_equal [login_for(@exec)], mine.first.owners
    assert_equal Rails.application.routes.url_helpers.admin_contributor_path(@exec, ledger: @ledger.id),
      mine.first.subject_url
    assert_equal "Contributor has an MSO true-up to accept", mine.first.humanized_type
    assert_no_match(/1000|1,000/, mine.first.subject_display_name(redact_amounts: true))
  end

  test "an accepted true-up needs no task" do
    @trueup.toggle_acceptance!

    assert_empty tasks.select { |task| task.subject == @exec }
  end

  # Nobody can accept a true-up that has a QuickBooks bill (MsoTrueup::Locked),
  # so its executive is not asked to. (An unaccepted row with a bill is what a
  # failed "Remove QuickBooks bill" leaves behind; an admin has to act.)
  test "a true-up with a QuickBooks bill raises no task its executive could not clear" do
    @trueup.update_columns(qbo_bill_id: "77")
    assert_raises(MsoTrueup::Locked) { MsoTrueup.find(@trueup.id).toggle_acceptance! }

    assert_empty tasks.select { |task| task.subject == @exec }
  end

  test "a removed true-up needs no task" do
    @trueup.destroy

    assert_empty tasks.select { |task| task.subject == @exec }
  end

  test "an executive with a true-up and no garden3d QuickBooks vendor is flagged for a vendor mapping" do
    vendor_tasks = lambda do
      Stacks::TaskBuilder::Discoveries::MissingQboVendors.new(admin_fallback: [mso_admin]).tasks
        .select { |task| task.subject == @ledger }
    end

    assert_equal [:missing_qbo_vendor_for_contributor], vendor_tasks.call.map(&:type)

    vendor = QboVendor.create!(qbo_account: garden3d_qbo_account, qbo_id: "V-#{SecureRandom.hex(3)}", data: {})
    ContributorQboVendor.create!(contributor: @exec, qbo_account: garden3d_qbo_account, qbo_vendor: vendor)

    assert_empty vendor_tasks.call
  end
end
