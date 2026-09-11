# Proves the proxy is a one-to-one mirror: for a fixed set of real ids, the
# proxy's response (cold, then warm) must equal Notion's own, ignoring the
# per-request keys. Run by test/live/notion_parity_test.rb (NOTION_LIVE=1) and
# by `bin/rails stacks:notion:verify_parity`. Makes real Notion requests.
class Stacks::Notion::Parity
  IGNORED = Stacks::Notion::Mirror::VOLATILE_KEYS
  HOM_GUIDE_PAGE = "3bf131fea2c7809287f3c668e91d5332"   # plain page (title property key "title")
  LEADS_DB       = "4d9b46b8bad542509f144347db37964d"
  LEADS_DS       = "8ac2bac5-bc47-4674-851e-d1b1e4f779f2"
  TASKS_DS       = "e5d5d0da-a85e-4b3f-b900-9fd06a315622"

  def initialize(app_base_url: nil, api_key: nil, io: $stdout)
    @base = app_base_url
    @key = api_key || Stacks::Utils.config[:stacks][:private_api_key]
    @io = io
    @notion = Stacks::Notion.new
    @result = { passed: 0, failed: 0, failures: [] }
  end

  def self.run(**opts) = new(**opts).run

  def run
    leads_row = @notion.query_data_source(LEADS_DS, { "page_size" => 1 })["results"].first["id"]

    check("GET pages/:id (plain page) cold=miss")   { compare_get("/pages/#{HOM_GUIDE_PAGE}", @notion.get_page(HOM_GUIDE_PAGE), expect: "miss") }
    check("GET pages/:id (plain page) warm=hit")    { compare_get("/pages/#{HOM_GUIDE_PAGE}", @notion.get_page(HOM_GUIDE_PAGE), expect: "hit") }
    check("GET pages/:id (database row) cold/warm") { compare_get("/pages/#{leads_row}", @notion.get_page(leads_row)); compare_get("/pages/#{leads_row}", @notion.get_page(leads_row), expect: "hit") }
    check("GET databases/:id")                      { compare_get("/databases/#{LEADS_DB}", @notion.get_database(LEADS_DB)); compare_get("/databases/#{LEADS_DB}", @notion.get_database(LEADS_DB), expect: "hit") }
    check("GET data_sources/:id")                   { compare_get("/data_sources/#{LEADS_DS}", @notion.get_data_source(LEADS_DS)); compare_get("/data_sources/#{LEADS_DS}", @notion.get_data_source(LEADS_DS), expect: "hit") }
    check("GET blocks/:id/children every cursor page, cold then warm") { compare_level(HOM_GUIDE_PAGE) }
    check("POST data_sources/:id/query with filter (live)") do
      body = { "filter" => { "timestamp" => "last_edited_time", "last_edited_time" => { "after" => 7.days.ago.utc.iso8601 } }, "page_size" => 5 }
      compare_post("/data_sources/#{TASKS_DS}/query", body, @notion.query_data_source(TASKS_DS, body), expect: "live", tolerate_edit_drift: true)
    end
    check("POST search (live)") do
      body = { "query" => "Human Operating Manual", "page_size" => 3 }
      compare_post("/search", body, @notion.search(body), expect: "live", tolerate_edit_drift: true)
    end
    check("row seeded from a search result then GET pages/:id equals Notion's GET") do
      hit = @notion.search({ "query" => "Leads", "page_size" => 5, "filter" => { "property" => "object", "value" => "page" } })["results"].first
      NotionPage.with_deleted.where(notion_id: Stacks::Notion::Ids.normalize(hit["id"])).each(&:destroy_fully!)
      Stacks::Notion::Mirror.upsert_page(hit)
      compare_get("/pages/#{hit['id']}", @notion.get_page(hit["id"]), expect: "hit")
    end

    @io.puts "parity: #{@result[:passed]} passed, #{@result[:failed]} failed"
    @result[:failures].each { |f| @io.puts "  FAIL #{f}" }
    @result
  end

  private

  def check(name)
    yield
    @result[:passed] += 1
    @io.puts "  ok   #{name}"
  rescue => e
    @result[:failed] += 1
    @result[:failures] << "#{name}: #{e.message.lines.first&.strip}"
    @io.puts "  FAIL #{name}: #{e.message}"
  end

  def scrub(h) = h.deep_dup.tap { |x| IGNORED.each { |k| x.delete(k) } }

  def compare_get(path, notion_body, expect: nil)
    status, headers, body = proxy(:get, path)
    raise "proxy #{status}: #{body}" unless status == 200
    raise "expected X-Stacks-Cache=#{expect}, got #{headers['X-Stacks-Cache']}" if expect && headers["X-Stacks-Cache"] != expect
    diff = Hashdiff.diff(scrub(notion_body), scrub(body))
    raise "body differs: #{diff.first(5).inspect}" unless diff.empty?
  end

  def compare_post(path, req_body, notion_body, expect:, tolerate_edit_drift: false)
    status, headers, body = proxy(:post, path, req_body)
    raise "proxy #{status}: #{body}" unless status == 200
    raise "expected X-Stacks-Cache=#{expect}, got #{headers['X-Stacks-Cache']}" if headers["X-Stacks-Cache"] != expect
    a = scrub(notion_body); b = scrub(body)
    if tolerate_edit_drift
      a = a.merge("results" => a["results"].map { |r| r["id"] }); b = b.merge("results" => b["results"].map { |r| r["id"] })
      a.delete("next_cursor"); b.delete("next_cursor")
    end
    diff = Hashdiff.diff(a, b)
    raise "body differs: #{diff.first(5).inspect}" unless diff.empty?
  end

  def compare_level(parent)
    cursor = nil
    loop do
      notion = @notion.get_block_children(parent, start_cursor: cursor, page_size: 100)
      status, _headers, body = proxy(:get, "/blocks/#{parent}/children#{cursor ? "?start_cursor=#{cursor}" : ""}")
      raise "proxy #{status}" unless status == 200
      diff = Hashdiff.diff(scrub(notion).except("next_cursor"), scrub(body).except("next_cursor"))
      raise "cold level differs at cursor=#{cursor.inspect}: #{diff.first(5).inspect}" unless diff.empty?
      cursor = notion["next_cursor"]
      break if cursor.nil?
    end
    # warm: the whole level must now come from cache and equal Notion's concatenation
    notion_all = Stacks::Notion::TreeFetcher.fetch_level(@notion, parent_id: parent, page_id: parent).first.map { |b| scrub(b) }
    proxied = []
    cursor = nil
    loop do
      status, headers, body = proxy(:get, "/blocks/#{parent}/children#{cursor ? "?start_cursor=#{cursor}" : ""}")
      raise "proxy #{status}" unless status == 200
      raise "warm level not a hit (#{headers['X-Stacks-Cache']})" unless headers["X-Stacks-Cache"] == "hit"
      proxied.concat(body["results"].map { |b| scrub(b) })
      cursor = body["next_cursor"]
      break if cursor.nil?
    end
    diff = Hashdiff.diff(notion_all, proxied)
    raise "warm level differs: #{diff.first(5).inspect}" unless diff.empty?
  end

  # → [status, headers, parsed_body]
  def proxy(method, path, body = nil)
    if @base
      resp = HTTParty.send(method, "#{@base}/api/notion/v1#{path}", headers: { "X-Api-Key" => @key, "Content-Type" => "application/json" }, body: body&.to_json)
      # HTTParty headers are a Net::HTTPHeader: to_h yields Array values.
      headers = resp.headers.to_h.each_with_object({}) do |(k, v), h|
        h[k.to_s.split("-").map(&:capitalize).join("-")] = v.is_a?(Array) ? v.first : v
      end
      [resp.code, headers, resp.parsed_response]
    else
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.host! "localhost"
      session.send(method, "/api/notion/v1#{path}", params: body&.to_json, headers: { "X-Api-Key" => @key, "Content-Type" => "application/json" })
      [session.response.status, session.response.headers, JSON.parse(session.response.body)]
    end
  end
end
