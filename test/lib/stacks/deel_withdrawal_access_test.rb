require "test_helper"

class Stacks::DeelWithdrawalAccessTest < ActiveSupport::TestCase
  test "allowlists christian@sanctuary.computer by default when config omits list" do
    Stacks::Utils.stubs(:config).returns({ deel: {} })

    assert Stacks::DeelWithdrawalAccess.allowlisted?("christian@sanctuary.computer")
    refute Stacks::DeelWithdrawalAccess.allowlisted?("other@example.com")
  end

  test "respects manual_invoice_allowed_emails from config" do
    Stacks::Utils.stubs(:config).returns({
      deel: { manual_invoice_allowed_emails: "one@x.com, Two@y.com" },
    })

    assert Stacks::DeelWithdrawalAccess.allowlisted?("one@x.com")
    assert Stacks::DeelWithdrawalAccess.allowlisted?("two@y.com")
    refute Stacks::DeelWithdrawalAccess.allowlisted?("christian@sanctuary.computer")
  end

  test "legacy manual_withdrawal_allowed_emails config key still works" do
    Stacks::Utils.stubs(:config).returns({
      deel: { manual_withdrawal_allowed_emails: "legacy@x.com" },
    })

    assert Stacks::DeelWithdrawalAccess.allowlisted?("legacy@x.com")
    refute Stacks::DeelWithdrawalAccess.allowlisted?("christian@sanctuary.computer")
  end
end
