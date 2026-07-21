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
        filter: "email:'#{email.to_s.downcase}'", include: "labels,newsletters",
      }, headers: headers)
    }
    (response.parsed_response["members"] || []).first
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
