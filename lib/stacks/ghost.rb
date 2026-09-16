require 'jwt'

class Stacks::Ghost
  include HTTParty

  class RequestError < StandardError
    attr_reader :code

    def initialize(code, body)
      @code = code
      super("Ghost API #{code}: #{body.to_s.first(500)}")
    end

    def retryable?
      code == 429 || code >= 500
    end
  end

  # Raised when a member's event history cannot be trusted to be complete and
  # correct. The events endpoint returns 200 with an empty list for a nonexistent
  # OR malformed member id, so "no events" is not evidence of "never subscribed".
  # Callers MUST treat this as fail-closed: no grants.
  class UntrustworthyHistory < StandardError; end

  MEMBER_ID_FORMAT = /\A[0-9a-f]{24}\z/.freeze
  EVENTS_PAGE_LIMIT = 100
  EVENTS_MAX_PAGES = 20

  # max_retries: backoff count for 429/5xx. Request-path callers (webhooks,
  # admin buttons) should keep this small; the cron sweep can afford retries.
  def initialize(max_retries: 5)
    @max_retries = max_retries
    config = Stacks::Utils.config[:ghost]
    @api_url = config[:api_url]
    @key_id, @secret_hex = config[:admin_api_key].to_s.split(":")
  end

  # Ghost admin JWTs are short-lived and signed with the hex-decoded secret.
  def token
    now = Time.now.to_i
    JWT.encode(
      { iat: now, exp: now + 300, aud: "/admin/" },
      [@secret_hex].pack("H*"),
      "HS256",
      { kid: @key_id }
    )
  end

  def all_members
    members = []
    page = 1
    loop do
      response = handle_response {
        self.class.get(url("/members/"), query: {
          limit: 100, page: page, include: "labels,newsletters",
        }, headers: headers)
      }
      members += response.parsed_response["members"] || []
      break if response.parsed_response.dig("meta", "pagination", "next").nil?
      page += 1
    end
    members
  end

  def find_member_by_email(email)
    response = handle_response {
      self.class.get(url("/members/"), query: {
        filter: "email:'#{email.to_s.downcase.gsub("'", "\\\\'")}'", include: "labels,newsletters",
      }, headers: headers)
    }
    (response.parsed_response["members"] || []).first
  end

  def all_newsletters
    response = handle_response {
      self.class.get(url("/newsletters/"), query: { limit: "all" }, headers: headers)
    }
    response.parsed_response["newsletters"] || []
  end

  def create_member(attrs)
    response = handle_response {
      self.class.post(url("/members/"), query: { include: "labels,newsletters" },
        body: JSON.dump({ members: [attrs] }), headers: headers)
    }
    response.parsed_response["members"].first
  end

  def update_member(id, attrs)
    response = handle_response {
      self.class.put(url("/members/#{id}/"), query: { include: "labels,newsletters" },
        body: JSON.dump({ members: [attrs] }), headers: headers)
    }
    response.parsed_response["members"].first
  end

  def find_member(id)
    response = handle_response {
      self.class.get(url("/members/#{id}/"), query: { include: "labels,newsletters" }, headers: headers)
    }
    (response.parsed_response["members"] || []).first
  end

  # Returns every newsletter_event for a member, or raises UntrustworthyHistory.
  # current_newsletter_ids enables the coherence check: a member currently
  # subscribed to something must have at least one event.
  def newsletter_events_for(member_id, current_newsletter_ids: [])
    unless member_id.to_s.match?(MEMBER_ID_FORMAT)
      raise UntrustworthyHistory, "refusing to query events for malformed member id #{member_id.inspect}"
    end

    collected = []
    cursor = nil
    total = nil
    pages = 0

    loop do
      pages += 1
      if pages > EVENTS_MAX_PAGES
        raise UntrustworthyHistory, "member #{member_id} exceeded #{EVENTS_MAX_PAGES} event pages"
      end

      # NQL quoting mirrors find_member_by_email. Quotes must be RAW: HTTParty
      # encodes the query itself, so a pre-encoded %27 arrives as %2527 and 422s.
      filter = "type:newsletter_event+data.member_id:'#{member_id}'"
      filter += "+data.created_at:<'#{cursor}'" if cursor

      response = handle_response {
        self.class.get(url("/members/events/"), query: {
          filter: filter, limit: EVENTS_PAGE_LIMIT, order: "created_at desc",
        }, headers: headers)
      }
      body = response.parsed_response
      page = body["events"] || []
      total ||= body.dig("meta", "pagination", "total")

      page.each do |event|
        actual = event.dig("data", "member_id")
        next if actual == member_id
        raise UntrustworthyHistory, "event for member #{actual.inspect} returned when querying #{member_id}"
      end

      collected += page
      break if page.length < EVENTS_PAGE_LIMIT

      oldest = page.map { |e| e.dig("data", "created_at") }.compact.min
      if oldest.nil? || (cursor && oldest >= cursor)
        raise UntrustworthyHistory, "member #{member_id} event cursor did not advance past #{cursor.inspect}"
      end
      cursor = oldest
    end

    if total && collected.length < total
      raise UntrustworthyHistory, "collected #{collected.length} of #{total} events for member #{member_id}"
    end

    if collected.empty? && current_newsletter_ids.any?
      raise UntrustworthyHistory,
        "member #{member_id} is subscribed to #{current_newsletter_ids.length} newsletter(s) but has no events"
    end

    collected
  end

  private

  def url(path)
    "#{@api_url}/ghost/api/admin#{path}"
  end

  def headers
    {
      "Authorization" => "Ghost #{token}",
      "Content-Type" => "application/json",
      "Accept-Version" => "v6.0",
    }
  end

  def handle_response(&block)
    retry_count = 0
    begin
      response = block.call
      raise RequestError.new(response.code, response.body) unless response.success?
      response
    rescue RequestError => e
      raise e unless e.retryable? && retry_count < @max_retries
      retry_count += 1
      backoff(retry_count)
      retry
    end
  end

  def backoff(retry_count)
    sleep(2**retry_count)
  end
end
