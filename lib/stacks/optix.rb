# Optix API client. Optix is the co-working software some Enterprises use to
# track members. The client is constructed against one OptixOrganization,
# which scopes synced data — but credentials currently live globally in
# Rails.credentials, since for now we have exactly one Optix tenant. When a
# second tenant is needed, swap in a per-org credential lookup here.
#
# Credentials shape:
#   optix:
#     client_id:           "..."
#     client_secret:       "..."
#     organization_token:  "..."
#     personal_token:      "..."
#     api_base:            "https://api.optixapp.com"  # optional override
#
# Usage:
#   org = OptixOrganization.first
#   org.client.list_account_plans(status: ["ACTIVE"])
#   org.client.member_counts_by_tier_and_location
#
# The API is GraphQL — a single endpoint at /graphql that accepts {query,
# variables} JSON bodies and returns {data, errors}.
class Stacks::Optix
  include HTTParty

  GRAPHQL_PATH = "/graphql".freeze
  DEFAULT_API_BASE = "https://api.optixapp.com".freeze

  class ApiError < StandardError
    attr_reader :http_code, :graphql_errors

    def initialize(message = nil, http_code: nil, graphql_errors: nil)
      super(message)
      @http_code = http_code&.to_i
      @http_code = nil if @http_code&.zero?
      @graphql_errors = graphql_errors
    end

    def retryable?
      [429, 502, 503, 504].include?(http_code)
    end
  end

  attr_reader :optix_organization

  def initialize(optix_organization = nil)
    @optix_organization = optix_organization
  end

  # ---------- credentials (currently global; per-org in the future) ----------

  def api_base
    (credentials[:api_base].presence || DEFAULT_API_BASE).to_s.sub(%r{/+\z}, "")
  end

  def organization_token
    credentials[:organization_token]
  end

  def personal_token
    credentials[:personal_token]
  end

  def client_id
    credentials[:client_id]
  end

  def client_secret
    credentials[:client_secret]
  end

  # ---------- core query execution ----------

  # Execute a GraphQL operation against this org's Optix tenant.
  #
  # @param query [String]  GraphQL query / mutation document
  # @param variables [Hash] variables for the operation (optional)
  # @param token [String]  Bearer token; defaults to the org token of THIS org
  # @param operation_name [String, nil]
  # @return [Hash] the contents of the response's `data` key
  # @raise [ApiError] on HTTP non-2xx OR when the response contains GraphQL `errors`
  def execute(query:, variables: {}, token: organization_token, operation_name: nil)
    raise ApiError.new("Optix bearer token is not configured for OptixOrganization ##{optix_organization.id}") if token.blank?

    body = { query: query, variables: variables }
    body[:operationName] = operation_name if operation_name.present?

    response = self.class.post(
      "#{api_base}#{GRAPHQL_PATH}",
      headers: json_headers(token),
      body: body.to_json,
    )

    parsed = response.parsed_response

    unless (200..299).cover?(response.code)
      raise ApiError.new(
        "Optix HTTP #{response.code}: #{summarize_failure(parsed)}",
        http_code: response.code,
        graphql_errors: extract_graphql_errors(parsed),
      )
    end

    if parsed.is_a?(Hash) && parsed["errors"].is_a?(Array) && parsed["errors"].any?
      messages = parsed["errors"].map { |e| e["message"] }.compact.join("; ")
      raise ApiError.new(
        "Optix GraphQL errors: #{messages}",
        http_code: response.code,
        graphql_errors: parsed["errors"],
      )
    end

    parsed.is_a?(Hash) ? parsed["data"] : parsed
  end

  def execute_as_organization(query:, variables: {}, operation_name: nil)
    execute(query: query, variables: variables, operation_name: operation_name, token: organization_token)
  end

  def execute_as_user(query:, variables: {}, operation_name: nil)
    execute(query: query, variables: variables, operation_name: operation_name, token: personal_token)
  end

  # ---------- sanity check / introspection ----------

  def ping(token: organization_token)
    execute(
      token: token,
      query: "query Ping { __schema { queryType { name } } }",
    )
  end

  def introspect_type(type_name)
    execute(query: <<~GQL, variables: { name: type_name })
      query Introspect($name: String!) {
        __type(name: $name) {
          name
          kind
          description
          fields {
            name
            description
            args { name type { name kind ofType { name kind } } }
            type {
              name
              kind
              ofType { name kind ofType { name kind ofType { name kind } } }
            }
          }
        }
      }
    GQL
  end

  # ---------- typed methods ----------

  # Pages through users (members) and returns Array<Hash>. Used by OptixSync
  # to populate optix_users. Conservative field set — `User` field availability
  # varies between Optix versions; introspect `User` to see what else is queryable
  # and add fields here + columns in optix_users + mapping in OptixSync as needed.
  def list_users(page_size: 100)
    paginate(page_size: page_size) do |limit, page|
      execute(query: <<~GQL, variables: { limit: limit, page: page })
        query Users($limit: Int, $page: Int) {
          users(limit: $limit, page: $page) {
            total
            data {
              user_id
              email
              name
              surname
              is_active
            }
          }
        }
      GQL
    end
  end

  # Pages through locations.
  #
  # NOTE on include_* flags: Optix's `locations` query treats include_visible /
  # include_hidden / include_deleted as opt-in filters. Setting any of them
  # without the others can silently exclude categories you'd expect to keep —
  # e.g. setting include_hidden: true alone drops visible locations from the
  # result. We pass all three explicitly so the sync captures every location
  # regardless of state (hidden/deleted ones still hold historical relevance
  # for past membership data).
  def list_locations(page_size: 100)
    paginate(page_size: page_size) do |limit, page|
      execute(query: <<~GQL, variables: { limit: limit, page: page })
        query Locations($limit: Int, $page: Int) {
          locations(
            limit: $limit,
            page: $page,
            include_visible: true,
            include_hidden: true,
            include_deleted: true
          ) {
            total
            data {
              location_id
              name
              city
              region
              country
              timezone
              is_visible
              is_hidden
              is_deleted
            }
          }
        }
      GQL
    end
  end

  # Pages through plan templates.
  def list_plan_templates(page_size: 100)
    paginate(page_size: page_size) do |limit, page|
      execute(query: <<~GQL, variables: { limit: limit, page: page })
        query PlanTemplates($limit: Int, $page: Int) {
          planTemplates(limit: $limit, page: $page) {
            total
            data {
              plan_template_id
              name
              price
              price_frequency
              in_all_locations
              onboarding_enabled
              non_onboarding_enabled
              locations { location_id name }
            }
          }
        }
      GQL
    end
  end

  # Pages through accountPlans and returns slim Array<Hash>.
  # Defaults to ALL statuses so we keep historical data for churn analysis.
  def list_account_plans(status: nil, page_size: 100)
    results = []
    page = 1
    loop do
      variables = { limit: page_size, page: page }
      variables[:status] = status if status

      data = execute(query: <<~GQL, variables: variables)
        query AccountPlans($limit: Int, $page: Int, $status: [AccountPlanStatus!]) {
          accountPlans(limit: $limit, page: $page, status: $status) {
            total
            data {
              account_plan_id
              name
              status
              price
              price_frequency
              start_timestamp
              end_timestamp
              canceled_timestamp
              created_timestamp
              access_usage_user { user_id email }
              plan_template {
                plan_template_id
                name
                in_all_locations
                locations { location_id name }
              }
            }
          }
        }
      GQL

      page_data = data.dig("accountPlans", "data") || []
      total = data.dig("accountPlans", "total")
      results.concat(page_data)

      break if page_data.length < page_size
      break if total && results.length >= total
      page += 1
    end

    results
  end

  # Roll-up of memberships by (location, tier). Multi-location plans contribute
  # one count per available location; `in_all_locations` plans bucket under
  # "All Locations". This is the live-API version — once OptixSync has
  # populated the DB, prefer the same name on OptixOrganization that queries
  # locally.
  def member_counts_by_tier_and_location(status: ["ACTIVE"])
    plans = list_account_plans(status: status)

    counts = Hash.new(0)
    plans.each do |plan|
      template = plan["plan_template"]
      next unless template

      tier = template["name"]
      if template["in_all_locations"]
        counts[{ location: "All Locations", tier: tier }] += 1
      else
        (template["locations"] || []).each do |loc|
          counts[{ location: loc["name"] || "(unnamed)", tier: tier }] += 1
        end
      end
    end

    counts
      .map { |k, v| { location: k[:location], tier: k[:tier], count: v } }
      .sort_by { |row| [row[:location], row[:tier]] }
  end

  private

  # Generic pagination wrapper. The block receives (limit, page) and must
  # return the parsed `data` hash from a query whose top-level field is a
  # Pagination object with shape { total, data: [...] }. Stops on partial
  # page or when accumulated count matches `total`.
  def paginate(page_size: 100)
    results = []
    page = 1
    loop do
      data = yield(page_size, page)
      # The first key of the data is the pagination wrapper.
      pagination = data.values.first
      page_data = pagination.is_a?(Hash) ? (pagination["data"] || []) : []
      total = pagination.is_a?(Hash) ? pagination["total"] : nil
      results.concat(page_data)

      break if page_data.length < page_size
      break if total && results.length >= total
      page += 1
    end
    results
  end

  def credentials
    @credentials ||= (Stacks::Utils.config&.dig(:optix) || {})
  end

  def json_headers(bearer)
    {
      "Accept" => "application/json",
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{bearer}",
    }
  end

  def extract_graphql_errors(parsed)
    return nil unless parsed.is_a?(Hash)
    parsed["errors"]
  end

  def summarize_failure(parsed)
    errs = extract_graphql_errors(parsed)
    return errs.map { |e| e["message"] }.join("; ") if errs.is_a?(Array) && errs.any?
    parsed.is_a?(Hash) ? (parsed["message"] || parsed.to_s) : parsed.to_s
  end
end
