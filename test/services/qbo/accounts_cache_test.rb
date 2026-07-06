require "test_helper"
require "ostruct"

class Qbo::AccountsCacheTest < ActiveSupport::TestCase
  test "fetches accounts once per qbo_account and memoizes by id" do
    accounts = [OpenStruct.new(name: "A", acct_num: "1")]
    qa = mock("qbo_account")
    qa.stubs(:id).returns(7)
    qa.expects(:fetch_all_accounts).once.returns(accounts)

    cache = Qbo::AccountsCache.new
    assert_same accounts, cache.accounts_for(qa)
    assert_same accounts, cache.accounts_for(qa) # second call: no second fetch
  end

  test "fetches separately for different qbo_accounts" do
    a1 = [OpenStruct.new(name: "A")]
    a2 = [OpenStruct.new(name: "B")]
    qa1 = mock("qa1"); qa1.stubs(:id).returns(1); qa1.expects(:fetch_all_accounts).once.returns(a1)
    qa2 = mock("qa2"); qa2.stubs(:id).returns(2); qa2.expects(:fetch_all_accounts).once.returns(a2)

    cache = Qbo::AccountsCache.new
    assert_same a1, cache.accounts_for(qa1)
    assert_same a2, cache.accounts_for(qa2)
  end
end
