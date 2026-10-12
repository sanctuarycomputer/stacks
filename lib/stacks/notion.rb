require 'uri'
require 'net/http'

class Stacks::Notion
  include HTTParty
  base_uri 'https://api.notion.com/v1'

  DATABASE_IDS = {
    LEADS: "4d9b46b8bad542509f144347db37964d",
    HUMAN_OPERATING_MANUALS: "5d59dcd95bfb458a9747ce7d6ce9e009",
    # Projects: a tracker picks its page from these (app/admin/project_trackers.rb).
    PROJECTS: "713b28db4f8a45c68126e9723c65349e",
  }

  # Stacksbot's tables, read by the filtered sync (Stacks::Notion::FilteredSync)
  # for the project log. They are NOT in DATABASE_IDS and must never be:
  # sync_database deletes every row under a database that it did not see, and
  # these are only ever read in part.
  FILTERED_DATABASES = {
    OBSERVATIONS: { id: "390131fea2c7808bb216c38b46c3ba55", project_property: "Projects" },
    PROBLEMS: { id: "18d6276a12aa4e0a957f013a69d5bb9a", project_property: "Project" },
  }.freeze

  # notion_pages.notion_parent_id of a filtered database's rows.
  def self.filtered_parent_id(key)
    Stacks::Utils.dashify_uuid(FILTERED_DATABASES.fetch(key)[:id])
  end

  class Error < StandardError
    attr_reader :status, :code

    def initialize(message, status: nil, code: nil)
      super(message)
      @status = status
      @code = code
    end
  end

  RETRY_ATTEMPTS = 5
  MAX_RETRY_WAIT = 30 # seconds

  attr_writer :sleeper

  # Strips what changes on every read (icons, covers and file properties
  # carry hourly-expiring S3 URLs), so a stored page diffs clean against a
  # fresh one. File properties keep "name" and "type" so superpowers_pdf?
  # (array presence) still works. Returns the page title: the first fragment
  # of the title property.
  def self.normalize_page!(r)
    r.delete("icon")
    r.delete("cover")
    props = r["properties"]
    return "" unless props.is_a?(Hash)
    props.each_value do |prop|
      next unless prop.is_a?(Hash) && prop["type"] == "files"
      Array(prop["files"]).each { |f| f.delete("file") if f.is_a?(Hash) }
    end
    title = props.values.find { |v| v.is_a?(Hash) && v["type"] == "title" }
    fragments = title && title["title"]
    first = fragments.is_a?(Array) ? fragments.first : nil
    (first.is_a?(Hash) && first["plain_text"].is_a?(String) ? first["plain_text"] : nil) || ""
  end

  def initialize()
    @headers = {
      "Authorization": "Bearer #{Stacks::Utils.config[:notion][:token]}",
      "Notion-Version" => "2021-05-13",
      "Content-Type" => "application/json"
    }
  end

  def get_users
    self.class.get("/users", headers: @headers)
  end

  def get_database(database_id)
    self.class.get("/databases/#{database_id}", headers: @headers)
  end

  def get_page(page_id)
    self.class.get("/pages/#{page_id}", headers: @headers)
  end

  def get_block_children(parent_block_id)
    self.class.get("/blocks/#{parent_block_id}/children", headers: @headers)
  end

  def create_database(parent_ref, title, properties = {})
    uri = URI("#{self.class.base_uri}/databases")
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    response = https.post(uri.path, {
      "parent" => parent_ref,
      "title" => [{
        "type": "text",
        "text": { "content": title }
      }],
      "properties" => properties
    }.to_json, @headers)
    JSON.parse(response.body)
  end

  def create_page(parent_ref, properties = {}, children = [])
    uri = URI("#{self.class.base_uri}/pages")
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    response = https.post(uri.path, {
      "parent" => parent_ref,
      "properties" => properties,
      "children" => children
    }.to_json, @headers)
    JSON.parse(response.body)
  end

  def append_block_children(parent_block_id, children)
    # Not sure why HTTParty didn't work
    uri = URI("#{self.class.base_uri}/blocks/#{parent_block_id}/children")
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    response = https.patch(uri.path, { "children" => children }.to_json, @headers)
    JSON.parse(response.body)
  end

  def query_database(database_id, start_cursor = nil)
    # Not sure why HTTParty didn't work
    uri = URI("#{self.class.base_uri}/databases/#{database_id}/query")
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    req = Net::HTTP::Post.new(uri.path, @headers)
    if start_cursor.present?
      req.body = {start_cursor: start_cursor}.to_json
    end
    response = https.request(req)
    JSON.parse(response.body)
  end

  def query_database_all(database_id, start_cursor = nil)
    results = []
    next_cursor = nil
    loop do
      response = query_database(database_id, next_cursor)
      results = [*results, *response["results"]]
      next_cursor = response["next_cursor"]
      break if next_cursor.nil?
    end
    results
  end

  # One page of a database query with a filter. Raises Stacks::Notion::Error
  # on anything but a 200, so a rejected filter is never read as "no rows".
  def query_database_filtered(database_id, filter:, sorts: nil, start_cursor: nil, page_size: 100)
    body = { page_size: page_size, filter: filter }
    body[:sorts] = sorts if sorts.present?
    body[:start_cursor] = start_cursor if start_cursor.present?
    _status, parsed = with_retry("query of database #{database_id}") { post_json("/databases/#{database_id}/query", body) }
    parsed
  end

  # One page by id. A 404 is an answer (the page is gone), not an error.
  def fetch_page(page_id)
    status, parsed = with_retry("fetch of page #{page_id}", allow: [404]) { get_json("/pages/#{page_id}") }
    { status: status, body: parsed }
  end

  def sync_database(database_id)
    if FILTERED_DATABASES.values.any? { |d| d[:id] == database_id.to_s.delete("-") }
      raise ArgumentError, "#{database_id} is read by the filtered sync only: a whole-database sync would delete its rows"
    end
    database_entries_touched = []
    next_cursor = nil
    loop do
      response = query_database(database_id, next_cursor)
      response["results"].each do |r|
        page_title = self.class.normalize_page!(r)
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

  private

  # Runs the block (which returns [status, retry_after, parsed]) until it
  # answers 200 or a status in `allow`. A 429 waits as long as Notion asks; a
  # 5xx or a timeout backs off 1, 2, 4, 8 seconds. Anything else raises now.
  def with_retry(what, allow: [])
    attempt = 0
    loop do
      attempt += 1
      status, retry_after, parsed =
        begin
          yield
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, EOFError => e
          [0, nil, { "message" => e.class.name }]
        end
      return [status, parsed] if status == 200 || allow.include?(status)

      if (status == 0 || status == 429 || status >= 500) && attempt < RETRY_ATTEMPTS
        wait = retry_after.to_f > 0 ? retry_after.to_f : 2**(attempt - 1)
        (@sleeper || ->(seconds) { sleep(seconds) }).call([wait, MAX_RETRY_WAIT].min)
        next
      end
      detail = parsed.is_a?(Hash) ? parsed : {}
      raise Error.new("Notion #{what} failed (#{status}): #{detail["message"]}", status: status, code: detail["code"])
    end
  end

  def post_json(path, body)
    uri = URI("#{self.class.base_uri}#{path}")
    req = Net::HTTP::Post.new(uri.path, @headers)
    req.body = body.to_json
    send_json(uri, req)
  end

  def get_json(path)
    uri = URI("#{self.class.base_uri}#{path}")
    send_json(uri, Net::HTTP::Get.new(uri.path, @headers))
  end

  def send_json(uri, req)
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    https.open_timeout = 10
    https.read_timeout = 60
    response = https.request(req)
    parsed = begin
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      {}
    end
    [response.code.to_i, response["Retry-After"], parsed]
  end
end
