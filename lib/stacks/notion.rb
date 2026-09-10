require 'uri'

# Stacks' only Notion HTTP client. Every request goes through #request, which
# paces starts to NOTION_RPS per process and honours Retry-After on 429/529.
# Spec: docs/superpowers/specs/2026-09-10-notion-mirror-design.md
class Stacks::Notion
  include HTTParty
  base_uri 'https://api.notion.com/v1'

  NOTION_VERSION = "2026-03-11".freeze
  DEFAULT_RPS = 0.6
  RETRYABLE_5XX = [500, 502, 503, 504].freeze

  DATABASE_IDS = {
    LEADS: "4d9b46b8bad542509f144347db37964d",
    HUMAN_OPERATING_MANUALS: "5d59dcd95bfb458a9747ce7d6ce9e009"
  }

  class RequestError < StandardError
    attr_reader :code, :body, :headers

    def initialize(code, body, headers = {})
      @code = code.to_i
      @body = body.is_a?(Hash) ? body : (JSON.parse(body.to_s) rescue { "message" => body.to_s })
      # HTTParty::Response::Headers is a Net::HTTPHeader: to_h gives Array values.
      @headers = headers.to_h.each_with_object({}) do |(k, v), h|
        h[k.to_s.downcase] = v.is_a?(Array) ? v.first : v
      end
      super("Notion API #{@code}: #{@body['code'] || @body['message']}")
    end

    def rate_limited?
      [429, 529].include?(code)
    end
  end

  class RateLimited < RequestError
    # Integer seconds Notion asked us to wait (default 2 when absent).
    def retry_after
      raw = headers["retry-after"]
      raw.to_s =~ /\A\d+\z/ ? raw.to_i : 2
    end
  end

  # ---- class-level pacer -------------------------------------------------
  # One Mutex + next-slot timestamp per PROCESS, so the proxy (a client per
  # request) and the sweep (one client) share the same spacing. The slot is
  # claimed under the mutex; the sleep happens outside it.
  @pacer_mutex = Mutex.new
  @next_slot = 0.0

  class << self
    def rps
      Float(ENV.fetch("NOTION_RPS", DEFAULT_RPS))
    end

    def reset_pacer!
      @pacer_mutex.synchronize { @next_slot = 0.0 }
    end

    def pace!
      interval = 1.0 / rps
      wait = @pacer_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        start_at = [now, @next_slot].max
        @next_slot = start_at + interval
        start_at - now
      end
      sleep(wait) if wait.positive?
    end
  end

  def initialize(max_retries: 3, retry_after_cap: 60)
    @max_retries = max_retries
    @retry_after_cap = retry_after_cap
    @headers = {
      "Authorization" => "Bearer #{Stacks::Utils.config[:notion][:token]}",
      "Notion-Version" => NOTION_VERSION,
      "Content-Type" => "application/json"
    }
  end

  # ---- endpoints (all return the parsed body Hash) ------------------------
  def get_users = request(:get, "/users")
  def get_page(page_id) = request(:get, "/pages/#{page_id}")
  def get_block(block_id) = request(:get, "/blocks/#{block_id}")

  def get_block_children(block_id, start_cursor: nil, page_size: 100)
    query = { page_size: page_size }
    query[:start_cursor] = start_cursor if start_cursor.present?
    request(:get, "/blocks/#{block_id}/children", query: query)
  end

  def get_database(database_id) = request(:get, "/databases/#{database_id}")
  def get_data_source(data_source_id) = request(:get, "/data_sources/#{data_source_id}")
  def query_data_source(data_source_id, body = {}) = request(:post, "/data_sources/#{data_source_id}/query", body: body)
  def search(body = {}) = request(:post, "/search", body: body)
  def create_page(body) = request(:post, "/pages", body: body)
  def update_page(page_id, body) = request(:patch, "/pages/#{page_id}", body: body)
  def append_block_children(block_id, body) = request(:patch, "/blocks/#{block_id}/children", body: body)
  def update_block(block_id, body) = request(:patch, "/blocks/#{block_id}", body: body)
  def delete_block(block_id) = request(:delete, "/blocks/#{block_id}")

  private

  def request(method, path, body: nil, query: nil)
    attempt = 0
    begin
      self.class.pace!
      opts = { headers: @headers }
      opts[:query] = query if query
      opts[:body] = body.to_json if body
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = self.class.public_send(method, path, opts)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.logger.info("[Stacks::Notion] #{method.to_s.upcase} #{path} #{response.code} #{ms}ms#{" retry_after=#{response.headers['retry-after']}" if response.code == 429}")
      return response.parsed_response if response.success?

      raise (response.code == 429 || response.code == 529 ? RateLimited : RequestError).new(response.code, response.parsed_response, response.headers)
    rescue RateLimited => e
      raise e if attempt >= @max_retries
      attempt += 1
      sleep([e.retry_after, @retry_after_cap].min)
      retry
    rescue RequestError => e
      raise e unless method == :get && RETRYABLE_5XX.include?(e.code) && attempt < @max_retries
      attempt += 1
      sleep(2**(attempt - 1))
      retry
    end
  end

  public

  # Full reconcile of one Stacks-owned database (Leads, Human Operating Manuals):
  # every row is upserted through the mirror; rows of that database_id that
  # Notion no longer returns are soft-deleted (TaskBuilder relies on them
  # disappearing). Rows that come back are recovered by Mirror.upsert_page.
  def sync_database(database_id)
    dashed_db = Stacks::Notion::Ids.normalize(database_id) or raise ArgumentError, "bad database id #{database_id.inspect}"
    ds_id = get_database(database_id).dig("data_sources", 0, "id") or raise "database #{database_id} has no data source"
    seen = []
    cursor = nil
    loop do
      page = query_data_source(ds_id, cursor ? { start_cursor: cursor } : {})
      page["results"].each do |obj|
        seen << Stacks::Notion::Mirror.upsert_page(obj).notion_id
      end
      cursor = page["next_cursor"]
      break if cursor.nil?
    end
    # An empty result must never wipe the database: where.not(notion_id: []) is 1=1.
    return { upserted: 0, removed: 0 } if seen.empty?

    removed = NotionPage.where(database_id: dashed_db).where.not(notion_id: seen).to_a
    removed.each(&:destroy)
    { upserted: seen.size, removed: removed.size }
  end
end
