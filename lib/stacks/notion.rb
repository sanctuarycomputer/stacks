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

  # Back-compat for callers that resolved rows by database id.
  def query_database_all(database_id)
    ds_id = get_database(database_id).dig("data_sources", 0, "id")
    results = []
    cursor = nil
    loop do
      page = query_data_source(ds_id, cursor ? { start_cursor: cursor } : {})
      results.concat(page["results"])
      cursor = page["next_cursor"]
      break if cursor.nil?
    end
    results
  end

  # Temporary shim so `sync_database` (below, rewritten in Task 5) keeps
  # working against the new data-source-based query API.
  def query_database(database_id, start_cursor = nil)
    ds_id = get_database(database_id).dig("data_sources", 0, "id")
    query_data_source(ds_id, start_cursor.present? ? { start_cursor: start_cursor } : {})
  end

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

  def sync_database(database_id)
    database_entries_touched = []
    next_cursor = nil
    loop do
      response = query_database(database_id, next_cursor)
      response["results"].each do |r|
        page_title = (r.dig("properties").values.find{|v| v["type"] == "title"}.dig("title", 0, "plain_text") || "")

        r.delete("icon") # Custom icons have an AWS Expiry that break our diff
        r.delete("cover") # Cover images have an AWS Expiry that break our diff
        # File properties embed hourly-expiring S3 URLs that make every page
        # diff dirty on every sync. Strip the volatile payload — keep only
        # "name" and "type" so superpowers_pdf? (array presence) still works.
        r.dig("properties")&.each_value do |prop|
          next unless prop.is_a?(Hash) && prop["type"] == "files"
          Array(prop["files"]).each { |f| f.delete("file") }
        end
        notion_id = r.dig("id")
        parent_type = r.dig("parent", "type")
        parent_id = r.dig("parent", parent_type)

        database_entries_touched << {
          notion_id: notion_id,
          notion_parent_type: parent_type,
          notion_parent_id: parent_id,
        }

        page =
          NotionPage.with_deleted.find_or_initialize_by(notion_id: notion_id)
        # If someone accidentally trashed this page, recover it
        page.recover! if page.deleted?
        if !page.persisted? || Hashdiff.diff(r, page.data).any?
          page.update!({
            notion_parent_type: parent_type,
            notion_parent_id: parent_id,
            data: r,
            page_title: page_title
          })
        end
      end
      next_cursor = response["next_cursor"]
      break if next_cursor.nil?
    end

    return if database_entries_touched.empty?
    NotionPage
      .where(
        notion_parent_type: database_entries_touched.first[:notion_parent_type],
        notion_parent_id: database_entries_touched.first[:notion_parent_id]
      ).where.not(
        notion_id: database_entries_touched.map{|n| n[:notion_id]}
      ).delete_all
  end
end
