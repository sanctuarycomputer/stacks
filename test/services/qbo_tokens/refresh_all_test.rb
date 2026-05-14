require "test_helper"

class QboTokens::RefreshAllTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @qa = qbo_accounts(:one)
    # Stub backoff so tests don't actually sleep.
    QboTokens::RefreshAll.stubs(:sleep_before_retry)
  end

  # ---------------------------------------------------------------------------
  # refresh_one
  # ---------------------------------------------------------------------------

  test "refresh_one returns ok Result when force-refresh succeeds" do
    @qa.expects(:make_and_refresh_qbo_access_token).with(force: true).returns("access-token-instance")

    result = QboTokens::RefreshAll.refresh_one(@qa)
    assert result.ok?
    assert_equal @qa, result.qbo_account
    assert result.refreshed
    assert_nil result.error
  end

  test "refresh_one does not retry when OAuth2::Error message contains invalid_grant" do
    err = OAuth2::Error.allocate
    def err.message; "invalid_grant: Token revoked"; end

    @qa.expects(:make_and_refresh_qbo_access_token).with(force: true).once.raises(err)

    result = QboTokens::RefreshAll.refresh_one(@qa)
    refute result.ok?
    refute result.refreshed
    assert_equal err, result.error
  end

  test "refresh_one retries up to MAX_ATTEMPTS on generic errors then returns error Result" do
    boom = StandardError.new("network blip")
    @qa.expects(:make_and_refresh_qbo_access_token).with(force: true).times(QboTokens::RefreshAll::MAX_ATTEMPTS).raises(boom)

    result = QboTokens::RefreshAll.refresh_one(@qa)
    refute result.ok?
    assert_equal boom, result.error
  end

  test "refresh_one returns ok if a retry succeeds after a transient failure" do
    boom = StandardError.new("transient")
    seq = sequence("retry-then-succeed")
    @qa.expects(:make_and_refresh_qbo_access_token).with(force: true).raises(boom).in_sequence(seq)
    @qa.expects(:make_and_refresh_qbo_access_token).with(force: true).returns("ok").in_sequence(seq)

    result = QboTokens::RefreshAll.refresh_one(@qa)
    assert result.ok?
    assert result.refreshed
  end

  # ---------------------------------------------------------------------------
  # call
  # ---------------------------------------------------------------------------

  test "call returns one Result per QboAccount that has a qbo_token" do
    # Both fixtures (qbo_accounts :one, :two) have qbo_tokens — expect 2 Results.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token).with(force: true).returns("ok")

    results = QboTokens::RefreshAll.call
    assert_equal 2, results.size
    assert results.all?(&:ok?)
  end

  test "call isolates per-enterprise — one bad token does not block the rest" do
    err = OAuth2::Error.allocate
    def err.message; "invalid_grant"; end

    # First call raises invalid_grant (no retry — short-circuits to error Result);
    # subsequent call (for the other qbo_account) succeeds.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token).with(force: true).raises(err).then.returns("ok")

    results = QboTokens::RefreshAll.call
    assert_equal 2, results.size
    assert_equal 1, results.count(&:ok?), "expected exactly one ok result"
    assert_equal 1, results.count { |r| !r.ok? }, "expected exactly one failed result"
    assert_includes results.reject(&:ok?).map(&:error), err
  end

  # ---------------------------------------------------------------------------
  # invalid_grant?
  # ---------------------------------------------------------------------------

  test "invalid_grant? returns false for non-OAuth2 errors" do
    refute QboTokens::RefreshAll.invalid_grant?(StandardError.new("invalid_grant"))
    refute QboTokens::RefreshAll.invalid_grant?(Faraday::ConnectionFailed.new("nope"))
  end

  test "invalid_grant? detects the three known revocation phrasings" do
    %w[invalid_grant Token\ revoked Token\ expired].each do |phrase|
      err = OAuth2::Error.allocate
      err.define_singleton_method(:message) { phrase }
      assert QboTokens::RefreshAll.invalid_grant?(err), "expected to match #{phrase.inspect}"
    end
  end
end
