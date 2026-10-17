require "test_helper"

# Founder true-ups are no longer made (the nightly job was retired once the
# founder was paid through the MSO), but the ones that exist can be deleted.
class TrueupDestroyTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2091, 1, 1)

  def teardown
    clear_enterprise_memos
  end

  test "deleting a founder true-up deletes its QuickBooks bill, and a paid bill refuses the delete" do
    InvoicePass.where(start_of_month: MONTH).destroy_all
    pass = InvoicePass.create!(start_of_month: MONTH, enterprise: enterprises(:sanctuary), data: {})
    ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: mso_person("tu-destroy", login: false))
    trueup = Trueup.create!(invoice_pass: pass, ledger: ledger, amount: "4000", description: "x", qbo_bill_id: "55")

    Trueup.any_instance.expects(:detach_and_destroy_qbo_bill).once
      .raises(SyncsAsQboBill::PaidQboBillError, "refusing to destroy QBO bill 55")
    assert_raises(SyncsAsQboBill::PaidQboBillError) { trueup.destroy }
    assert Trueup.find_by(id: trueup.id), "a refused delete leaves the row"

    Trueup.any_instance.expects(:detach_and_destroy_qbo_bill).once
    Trueup.find(trueup.id).destroy
    assert_nil Trueup.find_by(id: trueup.id)
  end
end
