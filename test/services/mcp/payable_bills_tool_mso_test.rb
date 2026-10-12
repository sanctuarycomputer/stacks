require "test_helper"

class Mcp::PayableBillsToolMsoTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 8, 1)

  def setup
    @qa = garden3d_qbo_account
    pass = garden3d_pass(MONTH)
    exec = mso_person("mcp-exec")
    ledger = garden3d_ledger(exec)
    role = mso_role(exec)
    snapshot = mso_snapshot(pass, lines: [mso_line(role, ledger, trueup: "1200.0")])
    @trueup = mso_trueup(snapshot, role, ledger, amount: "1200")
    @vendor = QboVendor.create!(qbo_account: @qa, qbo_id: "V-#{SecureRandom.hex(3)}",
                                data: { "display_name" => "An Executive" })
    # A read tool must never destroy a bill: that deletes it in QuickBooks.
    QboBill.any_instance.stubs(:delete_qbo_bill!).raises(RuntimeError, "unexpected QuickBooks bill delete")
  end

  def teardown
    clear_enterprise_memos
  end

  def bill!(qbo_id, data)
    QboBill.create!(qbo_account: @qa, qbo_id: qbo_id, qbo_vendor_id: @vendor.qbo_id, data: data)
  end

  def garden3d_block
    payload = mcp_payload(Mcp::ListPayableBillsTool.call(entity: garden3d.name, server_context: {}))
    payload["entities"].first
  end

  test "an executive's MSO bill is not listed and not in the outstanding total" do
    bill!("601", { "doc_number" => "Stacks_#{@trueup.id}_MT", "total_amt" => 1200.0, "balance" => 1200.0 })
    @trueup.update_columns(qbo_bill_id: "601")
    # A leftover MSO bill no true-up points at any more is recognised by its doc number.
    bill!("602", { "doc_number" => "Stacks_999999_MT", "total_amt" => 800.0, "balance" => 800.0 })
    bill!("603", { "doc_number" => "B-603", "total_amt" => 50.0, "balance" => 50.0 })

    block = garden3d_block

    assert_equal ["B-603"], block["bills"].map { |bill| bill["doc_number"] }
    assert_in_delta 50.0, block["total_outstanding"], 0.001
    assert_no_match(/1200|800/, block.to_json)
  end

  test "a bill a true-up points at is left out whatever its stored data says, even when the true-up is deleted" do
    bill!("604", {})
    bill!("605", { "doc_number" => "renamed-by-hand", "total_amt" => 1200.0, "balance" => 1200.0 })
    @trueup.update_columns(qbo_bill_id: "605", deleted_at: Time.current)

    block = garden3d_block

    assert_equal [], block["bills"]
    assert_in_delta 0.0, block["total_outstanding"], 0.001
    # 604 is an ordinary unsynced mirror row: skipped and counted, as before.
    assert_equal 1, block["skipped_count"]
  end
end
