# GA4 Data API client (runReport) authenticated as a Google service account, used directly (no domain-wide
# delegation subject). The key: Heroku config GOOGLE_ANALYTICS_SERVICE_ACCOUNT_JSON when set, otherwise Stacks'
# existing service account (credentials google_oauth2.service_account, stacks@stacks-305217, the one the
# Meet/Gmail ETL uses). The account needs Viewer on the GA account (or each property) and the Analytics Data
# API enabled in its project. No key at all → configured? is false and nothing calls Google.
class Stacks::GoogleAnalytics
  ENV_KEY = "GOOGLE_ANALYTICS_SERVICE_ACCOUNT_JSON".freeze
  SCOPE = "https://www.googleapis.com/auth/analytics.readonly".freeze
  ENDPOINT = "https://analyticsdata.googleapis.com/v1beta".freeze
  ADMIN_ENDPOINT = "https://analyticsadmin.googleapis.com/v1beta".freeze
  PAGE_SIZE = 100_000
  MAX_ATTEMPTS = 3

  class NotConfigured < StandardError; end
  class Error < StandardError; end

  def self.configured?
    key_json.present?
  end

  # The env var wins; otherwise Stacks' existing service account from credentials.
  def self.key_json
    ENV[ENV_KEY].presence || Stacks::Utils.config&.dig(:google_oauth2, :service_account).presence
  rescue StandardError
    nil
  end

  def self.key_source
    ENV[ENV_KEY].present? ? ENV_KEY : "credentials google_oauth2.service_account"
  end

  def initialize(json: self.class.key_json, sleeper: ->(s) { sleep(s) })
    raise NotConfigured, "no Google Analytics service-account key (#{ENV_KEY} or credentials google_oauth2.service_account)" if json.blank?

    @credentials = begin
      # Used directly: no sub/impersonation (analytics is not in the domain-wide delegation scopes).
      Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: StringIO.new(json), scope: SCOPE)
    rescue StandardError, ScriptError => e
      # Never pass e.message on: a JSON parse error echoes the input, which is the private key.
      raise NotConfigured, "the Google Analytics service-account key (#{self.class.key_source}) is not a valid service-account JSON key (#{e.class})"
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

  # Every GA4 property the service account can see (Admin API accountSummaries.list):
  # [{ property_id: "123", display_name: "garden3d.net", account: "accounts/9" }].
  def account_summaries
    out = []
    token = nil
    loop do
      json = request(:get, "#{ADMIN_ENDPOINT}/accountSummaries", query: { pageSize: 200, pageToken: token }.compact)
      Array(json["accountSummaries"]).each do |acct|
        Array(acct["propertySummaries"]).each do |p|
          out << { property_id: p["property"].to_s.delete_prefix("properties/"), display_name: p["displayName"].to_s, account: acct["account"] }
        end
      end
      token = json["nextPageToken"].presence
      break unless token
    end
    out
  end

  # The first web data stream's URL for a property, or nil.
  def web_stream_uri(property_id)
    json = request(:get, "#{ADMIN_ENDPOINT}/properties/#{property_id}/dataStreams", query: { pageSize: 50 })
    Array(json["dataStreams"]).find { |s| s["type"] == "WEB_DATA_STREAM" }&.dig("webStreamData", "defaultUri").presence
  end

  private

  def post(path, body)
    request(:post, "#{ENDPOINT}/#{path}", body: body)
  end

  def request(method, url, body: nil, query: nil)
    1.upto(MAX_ATTEMPTS) do |attempt|
      opts = { timeout: 60, headers: { "Authorization" => "Bearer #{access_token}", "Content-Type" => "application/json" } }
      opts[:body] = body.to_json if body
      opts[:query] = query if query
      res = HTTParty.public_send(method, url, **opts)
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
