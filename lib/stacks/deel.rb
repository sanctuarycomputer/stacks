class Stacks::Deel
  include HTTParty
  base_uri 'https://api.letsdeel.com/rest/v2'

  class ApiError < StandardError
    attr_reader :http_code

    def initialize(message = nil, http_code: nil)
      super(message)
      @http_code = http_code&.to_i
      @http_code = nil if @http_code&.zero?
    end

    def retryable_rate_limit?
      [429, 502, 503].include?(http_code)
    end
  end

  # -- Deel “invoice adjustments” API (org token: list/get/create line items on the contract pay cycle) ---

  def self.api_root
    cfg = Stacks::Utils.config[:deel] || {}
    (cfg[:api_base].presence || "https://api.letsdeel.com/rest/v2").to_s.sub(%r{/+\z}, "")
  end

  # Organization API token (`deel.api_key` or `deel.org_api_key`). Needs invoice-adjustments:write (and typically
  # invoice:create / invoice-adjustments:read) for submitting and listing contractor invoice line items.
  def self.org_bearer
    cfg = Stacks::Utils.config[:deel] || {}
    cfg[:org_api_key].presence || cfg[:api_key]
  end

  def self.json_headers(bearer)
    {
      "Accept" => "application/json",
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{bearer}",
    }
  end

  # invoice-adjustments:write (+ invoice scopes as required by Deel) — create line item on contract invoice / pay cycle.
  # `type` is Deel’s adjustment category enum (bonus, expense, other, …). Product UIs often hide it; default `other` is typical for period work.
  def self.create_invoice_adjustment!(amount:, contract_id:, description:, date_submitted:, type: "other")
    date_str =
      case date_submitted
      when Date
        date_submitted.iso8601
      when Time, DateTime
        date_submitted.to_date.iso8601
      when String
        Date.parse(date_submitted).iso8601
      else
        date_submitted.to_s
      end

    body = {
      data: {
        type: type,
        amount: amount.to_f,
        contract_id: contract_id.to_s,
        description: description.to_s,
        date_submitted: date_str,
      },
    }

    response = post(
      "#{api_root}/invoice-adjustments",
      headers: json_headers(org_bearer),
      body: body.to_json,
    )
    raise_api_error!(response, "create_invoice_adjustment")
    response.parsed_response
  end

  # Token scopes: invoice-adjustments:read
  def self.list_invoice_adjustments(contract_id:, statuses: ["pending"])
    q = {
      contract_id: contract_id,
      limit: "100",
      offset: "0",
      statuses: Array(statuses).join(","),
    }
    response = get(
      "#{api_root}/invoice-adjustments",
      query: q,
      headers: json_headers(org_bearer),
    )
    raise_api_error!(response, "list_invoice_adjustments")
    response.parsed_response
  end

  # Token scopes: invoice-adjustments:read
  def self.get_invoice_adjustment!(adjustment_id)
    response = get(
      "#{api_root}/invoice-adjustments/#{adjustment_id}",
      headers: json_headers(org_bearer),
    )
    raise_api_error!(response, "get_invoice_adjustment")
    response.parsed_response
  end

  def self.raise_api_error!(response, context)
    return if response.success?

    body = response.parsed_response
    message =
      if body.is_a?(Hash)
        errs = body["errors"]
        if errs.is_a?(Array) && errs.any?
          errs.map { |e| e["message"].presence }.compact.join("; ").presence
        end || body["message"]
      end
    message = message.presence || response.body.to_s[0, 500]
    code = response.code.to_i
    raise ApiError.new("#{context}: HTTP #{code} #{message}", http_code: code)
  end

  def initialize()
    @headers = {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "Authorization": "Bearer #{Stacks::Utils.config[:deel][:api_key]}",
    }
  end

  def sync_all!
    ActiveRecord::Base.transaction do
      DeelOffCyclePayment.delete_all
      DeelContract.delete_all
      DeelPerson.delete_all
      sync_people!
      sync_contracts!

      # TODO: Parallelize this
      DeelContract.all.each do |dc|
        sync_off_cycle_payments!(dc.deel_id)
      end
    end
  end

  def get_people
    values = []

    response = self.class.get("/people?limit=200", headers: @headers)
    values = response["data"]
    page = response["page"]

    loop do
      break if page["items_per_page"] + page["offset"] >= page["total_rows"]
      response = self.class.get("/people?limit=200&offset=#{page["items_per_page"] + page["offset"]}", headers: @headers)
      raise response unless response.success?
      values += response["data"]
      page = response["page"]
    end

    values
  end

  def sync_people!
    data = get_people.map do |p|
      {
        deel_id: p["id"],
        data: p,
      }
    end
    DeelPerson.upsert_all(data, unique_by: :deel_id)
  end

  def get_contracts
    values = []

    response = self.class.get("/contracts?limit=150", headers: @headers)
    values = response["data"]
    page = response["page"]

    loop do
      break if page["cursor"].blank?
      response = self.class.get("/contracts?limit=150&after_cursor=#{page["cursor"]}", headers: @headers)
      raise response unless response.success?
      values += response["data"]
      page = response["page"]
    end

    values
  end

  def sync_contracts!
    data = get_contracts.map do |c|
      next nil if c.dig("worker", "id").nil?
      {
        deel_id: c["id"],
        deel_person_id: c.dig("worker", "id"),
        data: c,
      }
    end.compact
    DeelContract.upsert_all(data, unique_by: :deel_id)
  end

  def get_off_cycle_payments(contract_id)
    response = self.class.get("/contracts/#{contract_id}/off-cycle-payments", headers: @headers)
    raise response unless response.success?
    response["data"]
  end

  def sync_off_cycle_payments!(contract_id)
    puts "Syncing off cycle payments for #{contract_id}"
    data = get_off_cycle_payments(contract_id).map do |op|
      {
        deel_id: op["id"],
        deel_contract_id: contract_id,
        data: op,
        created_at: op["created_at"],
        submitted_at: op["date_submitted"],
      }
    end
    DeelOffCyclePayment.upsert_all(data, unique_by: :deel_id) unless data.empty?
  end
end