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
end
