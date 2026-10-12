require "test_helper"

class AutomatorInvoicePassTest < ActiveSupport::TestCase
  def setup
    @sanctuary = enterprises(:sanctuary)
    @garden3d = enterprises(:garden3d)
    QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm",
                       client_id: "x", client_secret: "y")
  end

  def teardown
    # Enterprise.sanctuary / .garden3d memoize in Thread.current; a rolled-back
    # fixture row would otherwise leak into every later test on this thread.
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "attempt_invoicing_for_previous_month creates a Sanctuary pass" do
    month = (Date.today - 1.month).beginning_of_month
    InvoicePass.where(start_of_month: month).destroy_all
    Stacks::Automator.stubs(:attempt_invoicing_for_invoice_pass).returns(nil)

    Stacks::Automator.attempt_invoicing_for_previous_month

    assert InvoicePass.find_by(start_of_month: month, enterprise: @sanctuary).present?,
      "expected a Sanctuary pass for #{month}"
  end

  test "attempt_invoicing_for_previous_month ignores a garden3d pass for the same month" do
    month = (Date.today - 1.month).beginning_of_month
    InvoicePass.where(start_of_month: month).destroy_all
    InvoicePass.create!(start_of_month: month, enterprise: @garden3d, data: {},
                        completed_at: DateTime.now)
    Stacks::Automator.stubs(:attempt_invoicing_for_invoice_pass).returns(nil)

    Stacks::Automator.attempt_invoicing_for_previous_month

    assert InvoicePass.find_by(start_of_month: month, enterprise: @sanctuary).present?,
      "a completed garden3d pass must not satisfy the Sanctuary lookup"
  end

  test "attempt_invoicing_for_invoice_pass refuses a non-Sanctuary pass" do
    # Before the guard exists, the method's first statement reaches
    # remind_people_to_record_hours_prior_to_invoicing -> twist.get_workspace_users,
    # a real outbound HTTP call. Stub it so the red phase fails on the assertion
    # rather than on the network. Dead weight once the guard lands, kept so the
    # test does not depend on guard ordering.
    Stacks::Twist.any_instance.stubs(:get_workspace_users)
                 .returns(stub(parsed_response: []))

    pass = InvoicePass.create!(start_of_month: Date.new(2093, 1, 1),
                               enterprise: @garden3d, data: {})
    pass.expects(:make_trackers!).never

    Stacks::Automator.attempt_invoicing_for_invoice_pass(pass, false)

    assert_nil pass.reload.completed_at
  end
end
