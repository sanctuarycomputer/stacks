# GA4 Data API client (runReport) authenticated as a Google service account whose JSON key lives in
# Heroku config GOOGLE_ANALYTICS_SERVICE_ACCOUNT_JSON. The service account needs Viewer on each GA4
# property. Unset key → Stacks::GoogleAnalytics.configured? is false and nothing calls Google.
class Stacks::GoogleAnalytics
  ENV_KEY = "GOOGLE_ANALYTICS_SERVICE_ACCOUNT_JSON".freeze
  SCOPE = "https://www.googleapis.com/auth/analytics.readonly".freeze
  ENDPOINT = "https://analyticsdata.googleapis.com/v1beta".freeze
  PAGE_SIZE = 100_000
  MAX_ATTEMPTS = 3

  class NotConfigured < StandardError; end
  class Error < StandardError; end

  def self.configured?
    ENV[ENV_KEY].present?
  end

  def initialize(json: ENV[ENV_KEY], sleeper: ->(s) { sleep(s) })
    raise NotConfigured, "#{ENV_KEY} is not set" if json.blank?

    @credentials = begin
      Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: StringIO.new(json), scope: SCOPE)
    rescue StandardError, ScriptError => e
      # Never pass e.message on: a JSON parse error echoes the input, which is the private key.
      raise NotConfigured, "#{ENV_KEY} is not a valid service-account JSON key (#{e.class})"
    end
    @sleeper = sleeper
  end

  # The service account's email (to show in the admin, so Hugh knows what to add as Viewer).
  def client_email
    @credentials.issuer
  end

  # rows: [{ dimensions: [..strings..], metrics: [..numbers..] }], every page fetched.
  def run_report(property_id, date_from:, date_to:, dimensions:, metrics:, order_by_metric: nil)
    rows = []
    offset = 0
    loop do
      body = {
        dateRanges: [{ startDate: date_from.iso8601, endDate: date_to.iso8601 }],
        dimensions: dimensions.map { |d| { name: d } },
        metrics: metrics.map { |m| { name: m } },
        limit: PAGE_SIZE,
        offset: offset,
        keepEmptyRows: false,
      }
      body[:orderBys] = [{ metric: { metricName: order_by_metric }, desc: true }] if order_by_metric
      json = post("properties/#{property_id}:runReport", body)
      page = Array(json["rows"]).map do |r|
        { dimensions: Array(r["dimensionValues"]).map { |v| v["value"].to_s }, metrics: Array(r["metricValues"]).map { |v| v["value"].to_f } }
      end
      rows.concat(page)
      offset += page.size
      break if page.empty? || offset >= json["rowCount"].to_i
    end
    rows
  end

  private

  def post(path, body)
    1.upto(MAX_ATTEMPTS) do |attempt|
      res = HTTParty.post("#{ENDPOINT}/#{path}", body: body.to_json, timeout: 60,
                          headers: { "Authorization" => "Bearer #{access_token}", "Content-Type" => "application/json" })
      return res.parsed_response if res.code == 200

      message = res.parsed_response.is_a?(Hash) ? res.parsed_response.dig("error", "message") : res.body.to_s[0, 300]
      transient = res.code == 429 || res.code >= 500
      raise Error, "GA4 #{res.code}: #{message}" unless transient
      raise Error, "GA4 #{res.code} after #{attempt} attempts: #{message}" if attempt >= MAX_ATTEMPTS

      @sleeper.call(5 * attempt)
    end
  end

  def access_token
    if @token.nil? || @token_expires_at.nil? || Time.current >= @token_expires_at
      fetched = @credentials.fetch_access_token!
      @token = fetched["access_token"]
      @token_expires_at = Time.current + (fetched["expires_in"].to_i - 60).seconds
    end
    @token
  end
end
