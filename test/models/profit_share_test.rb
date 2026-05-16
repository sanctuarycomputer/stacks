require "test_helper"

class ProfitShareTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @ps = ProfitShare.new
  end

  # ProfitShare overrides find_qbo_account! so its bills accrue to a
  # dedicated liability account ("Accrued Profit Sharing") rather
  # than the contractor expense accounts used by the default routing.
  test "find_qbo_account! returns the profit-share liability account when present" do
    qa = mock("qbo_account")
    @ps.stubs(:qbo_account_for_bill).returns(qa)

    liability = OpenStruct.new(name: "Accrued Profit Sharing", acct_num: "2340", id: 2340)
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    qbo_accounts = [liability, default]

    account, studio = @ps.find_qbo_account!(qbo_accounts)
    assert_equal liability, account
    assert_nil studio, "no studio routing for profit-share liability account"
  end

  test "find_qbo_account! falls back to the default SyncsAsQboBill routing when the liability account is missing" do
    qa = mock("qbo_account")
    @ps.stubs(:qbo_account_for_bill).returns(qa)

    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    qbo_accounts = [default]

    # Stub the super call (SyncsAsQboBill#find_qbo_account!) by stubbing
    # the contributor + studio that the default implementation uses.
    contributor = mock("contributor")
    forecast_person = mock("forecast_person")
    forecast_person.stubs(:studio).returns(nil)
    contributor.stubs(:forecast_person).returns(forecast_person)
    @ps.stubs(:contributor).returns(contributor)

    account, _studio = @ps.find_qbo_account!(qbo_accounts)
    assert_equal default, account, "falls back to 'Contractors - Client Services' when 2340 missing"
  end
end
