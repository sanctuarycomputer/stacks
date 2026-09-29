require 'test_helper'

class Stacks::GoogleAnalyticsTest < ActiveSupport::TestCase
  KEY_JSON = {
    type: 'service_account', project_id: 'p', private_key_id: 'k', client_email: 'stacks-ga@p.iam.gserviceaccount.com',
    client_id: '1', private_key: OpenSSL::PKey::RSA.new(2048).to_pem, token_uri: 'https://oauth2.googleapis.com/token',
  }.to_json

  Res = Struct.new(:code, :parsed_response, :body)

  test 'configured? follows the env var; no key raises NotConfigured' do
    ClimateControl.modify(Stacks::GoogleAnalytics::ENV_KEY => nil) do
      refute Stacks::GoogleAnalytics.configured?
      assert_raises(Stacks::GoogleAnalytics::NotConfigured) { Stacks::GoogleAnalytics.new }
    end if defined?(ClimateControl)
    assert_raises(Stacks::GoogleAnalytics::NotConfigured) { Stacks::GoogleAnalytics.new(json: '') }
  end

  test 'run_report pages, retries a 429, and parses rows' do
    client = Stacks::GoogleAnalytics.new(json: KEY_JSON, sleeper: ->(_s) {})
    assert_equal 'stacks-ga@p.iam.gserviceaccount.com', client.client_email
    Google::Auth::ServiceAccountCredentials.any_instance.stubs(:fetch_access_token!).returns('access_token' => 't', 'expires_in' => 3600)
    page = { 'rowCount' => 1, 'rows' => [{ 'dimensionValues' => [{ 'value' => '20260928' }], 'metricValues' => [{ 'value' => '12' }, { 'value' => '1.5' }] }] }
    HTTParty.stubs(:post).returns(Res.new(429, { 'error' => { 'message' => 'quota' } }, ''), Res.new(200, page, ''))
    rows = client.run_report('123', date_from: Date.new(2026, 9, 28), date_to: Date.new(2026, 9, 28), dimensions: %w[date], metrics: %w[sessions keyEvents])
    assert_equal [{ dimensions: ['20260928'], metrics: [12.0, 1.5] }], rows
  end

  test 'a 403 is not retried and names the problem' do
    client = Stacks::GoogleAnalytics.new(json: KEY_JSON, sleeper: ->(_s) { flunk 'no retry on 403' })
    Google::Auth::ServiceAccountCredentials.any_instance.stubs(:fetch_access_token!).returns('access_token' => 't', 'expires_in' => 3600)
    HTTParty.stubs(:post).returns(Res.new(403, { 'error' => { 'message' => 'User does not have sufficient permissions' } }, ''))
    err = assert_raises(Stacks::GoogleAnalytics::Error) { client.run_report('123', date_from: Date.current, date_to: Date.current, dimensions: %w[date], metrics: %w[sessions]) }
    assert_match(/403: User does not have sufficient permissions/, err.message)
  end

  test 'a malformed key never echoes its content (the private key) in the error' do
    secret = '{"type":"service_account","private_key":"-----BEGIN PRIVATE KEY-----SECRETKEYMATERIAL'
    err = assert_raises(Stacks::GoogleAnalytics::NotConfigured) { Stacks::GoogleAnalytics.new(json: secret) }
    refute_includes err.message, 'SECRETKEYMATERIAL'
    refute_includes err.message, 'private_key'
    assert_match(/is not a valid service-account JSON key \(/, err.message)
  end

  test 'no env var: falls back to the existing Stacks service account; the env var wins when set' do
    Stacks::Utils.stubs(:config).returns({ google_oauth2: { service_account: KEY_JSON } })
    with_env(Stacks::GoogleAnalytics::ENV_KEY, nil) do
      assert Stacks::GoogleAnalytics.configured?
      assert_equal KEY_JSON, Stacks::GoogleAnalytics.key_json
      assert_equal 'stacks-ga@p.iam.gserviceaccount.com', Stacks::GoogleAnalytics.new.client_email
    end
    with_env(Stacks::GoogleAnalytics::ENV_KEY, '{"other":1}') { assert_equal '{"other":1}', Stacks::GoogleAnalytics.key_json }
    Stacks::Utils.stubs(:config).returns({})
    with_env(Stacks::GoogleAnalytics::ENV_KEY, nil) { refute Stacks::GoogleAnalytics.configured? }
  end

  test 'a malformed fallback key never echoes its content either' do
    Stacks::Utils.stubs(:config).returns({ google_oauth2: { service_account: '{"private_key":"SECRETKEYMATERIAL' } })
    with_env(Stacks::GoogleAnalytics::ENV_KEY, nil) do
      err = assert_raises(Stacks::GoogleAnalytics::NotConfigured) { Stacks::GoogleAnalytics.new }
      refute_includes err.message, 'SECRETKEYMATERIAL'
      assert_includes err.message, 'credentials google_oauth2.service_account'
    end
  end

  def with_env(key, value)
    old = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    old.nil? ? ENV.delete(key) : ENV[key] = old
  end

  test 'account_summaries pages through the Admin API and flattens properties' do
    client = Stacks::GoogleAnalytics.new(json: KEY_JSON, sleeper: ->(_s) {})
    Google::Auth::ServiceAccountCredentials.any_instance.stubs(:fetch_access_token!).returns('access_token' => 't', 'expires_in' => 3600)
    p1 = { 'accountSummaries' => [{ 'account' => 'accounts/1', 'propertySummaries' => [{ 'property' => 'properties/11', 'displayName' => 'A' }] }], 'nextPageToken' => 'n' }
    p2 = { 'accountSummaries' => [{ 'account' => 'accounts/2', 'propertySummaries' => [{ 'property' => 'properties/22', 'displayName' => 'B' }] }] }
    HTTParty.stubs(:get).returns(Res.new(200, p1, ''), Res.new(200, p2, ''))
    assert_equal [{ property_id: '11', display_name: 'A', account: 'accounts/1' }, { property_id: '22', display_name: 'B', account: 'accounts/2' }], client.account_summaries
  end
end
