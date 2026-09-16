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
  #
  # This endpoint returns 200 with an empty list for a nonexistent OR malformed member
  # id, so "no events" is not evidence of "never subscribed" unless every guard below
  # passes. Callers MUST treat the raise as fail-closed: no grants for this member.
  #
  # Deliberately does not page. Both `page` and `order` are silently ignored here
  # (verified live), so there is no reliable way to walk past the first 100 events and
  # no way to know which 100 we got. A member with more than 100 newsletter events fails
  # closed instead, which takes 100+ subscribe/unsubscribe toggles to reach.
  #
  # current_newsletter_ids has no default on purpose: the coherence guard is inert for
  # an empty list, and that is exactly the population at risk.
  def newsletter_events_for(member_id, current_newsletter_ids:)
    # The type check matters as much as the format: member_id.to_s would let a Symbol
    # with valid-looking hex content silently pass (":abc...".to_s still matches the
    # regex), so require an actual String before matching.
    unless member_id.is_a?(String) && member_id.match?(MEMBER_ID_FORMAT)
      raise UntrustworthyHistory, "refusing to query events for malformed member id #{member_id.inspect}"
    end
    # Coerce (a no-op given the check above) and use this value everywhere below, so a
    # future loosening of the check above can't reintroduce a non-String leaking into
    # the filter string or the provenance comparison.
    member_id = member_id.to_s

    # Quotes must be RAW: HTTParty encodes the query itself, so a pre-encoded %27
    # arrives as %2527 and 422s. Safe from injection because the guard above restricts
    # member_id to hex.
    response = handle_response {
      self.class.get(url("/members/events/"), query: {
        filter: "type:newsletter_event+data.member_id:'#{member_id}'",
        limit: EVENTS_PAGE_LIMIT,
      }, headers: headers)
    }

    body = response.parsed_response
    raise UntrustworthyHistory, "non-object events response for member #{member_id}" unless body.is_a?(Hash)

    events = body["events"]
    raise UntrustworthyHistory, "events was #{events.class} for member #{member_id}" unless events.is_a?(Array)

    total = body.dig("meta", "pagination", "total")
    unless total.is_a?(Integer)
      raise UntrustworthyHistory, "missing meta.pagination.total for member #{member_id}"
    end

    events.each do |event|
      unless event.is_a?(Hash) && event["data"].is_a?(Hash)
        raise UntrustworthyHistory, "malformed event entry for member #{member_id}"
      end
      unless event["type"] == "newsletter_event"
        raise UntrustworthyHistory, "unexpected event type #{event["type"].inspect} for member #{member_id}"
      end
      actual = event["data"]["member_id"]
      unless actual == member_id
        raise UntrustworthyHistory, "event for member #{actual.inspect} returned when querying #{member_id}"
      end
    end

    unless events.length == total
      raise UntrustworthyHistory, "collected #{events.length} of #{total} events for member #{member_id}"
    end

    if events.empty?
      if current_newsletter_ids.any?
        raise UntrustworthyHistory,
          "member #{member_id} is subscribed to #{current_newsletter_ids.length} newsletter(s) but has no events"
      end
      # Nothing above distinguishes "genuinely never subscribed" from "this id does not
      # exist", and both return 200 with an empty list. Confirm positively.
      unless find_member(member_id)
        raise UntrustworthyHistory, "no events and no such member #{member_id}"
      end
    end

    events
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
