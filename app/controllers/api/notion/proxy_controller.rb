# One-to-one caching reverse proxy of Notion's REST API. Same paths, bodies and
# responses as api.notion.com; cache hits never touch Notion; misses fill through
# Stacks::Notion (paced). Spec: docs/superpowers/specs/2026-09-10-notion-mirror-design.md
class Api::Notion::ProxyController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :require_api_key!

  # Child rescue_from wins over ApiController's blanket StandardError handler:
  # Notion's own error is passed through, untouched and without Sentry.
  rescue_from Stacks::Notion::RequestError, with: :render_notion_error

  # Rails' parameter parser raises this before the action runs (and before
  # json_body's own rescue can see it) when Content-Type: application/json
  # carries a malformed body.
  rescue_from ActionDispatch::Http::Parameters::ParseError do |_e|
    notion_error(400, "invalid_json", "Error parsing JSON body.")
  end

  # ---- single objects ------------------------------------------------------
  def get_page
    id = normalized_id!
    row = NotionPage.with_deleted.find_by(notion_id: id)
    return render_cached(row.data, fetched_at: row.page_fetched_at, state: "hit") if row && !row.deleted? && !row.access_lost

    obj = with_access_tracking(NotionPage.with_deleted.where(notion_id: id)) { client.get_page(id) }
    page = Stacks::Notion::Mirror.upsert_page(obj)
    render_cached(page.data, fetched_at: page.page_fetched_at, state: "miss")
  end

  def get_data_source
    id = normalized_id!
    row = NotionDataSource.find_by(notion_id: id)
    return render_cached(row.data, fetched_at: row.fetched_at, state: "hit") if row&.fetched_at

    row = Stacks::Notion::Mirror.upsert_data_source(client.get_data_source(id))
    render_cached(row.data, fetched_at: row.fetched_at, state: "miss")
  end

  def get_database
    id = normalized_id!
    row = NotionDatabase.find_by(notion_id: id)
    return render_cached(row.data, fetched_at: row.fetched_at, state: "hit") if row&.fetched_at

    row = Stacks::Notion::Mirror.upsert_database(client.get_database(id))
    render_cached(row.data, fetched_at: row.fetched_at, state: "miss")
  end

  def get_block
    # Notion block ids in the wild are uuids, but a block id the caller got from
    # us (e.g. Task 8's level-cache tests) must round-trip even when it isn't one.
    id = Stacks::Notion::Ids.normalize(params[:id]) || params[:id]
    row = NotionBlock.find_by(notion_id: id)
    return render_cached(row.data, fetched_at: row.updated_at, state: "hit") if row

    obj = client.get_block(id)
    parent_id = obj.dig("parent", "page_id") || obj.dig("parent", "block_id")
    page_id = Stacks::Notion::Mirror.owning_page_id(parent_id)
    if page_id
      Stacks::Notion::Mirror.store_blocks(parent_id: parent_id, page_id: page_id, blocks: [obj], position_offset: NotionBlock.where(parent_id: parent_id).count)
    end
    render_live(obj)
  end

  # Level cache: fresh → local slice; stale/never → the caller's ONE cursor page
  # live, stored opportunistically; unknown parent → live, not stored.
  def get_block_children
    parent_id = Stacks::Notion::Ids.normalize(params[:id]) || params[:id].to_s
    page_id = Stacks::Notion::Mirror.owning_page_id(parent_id)
    page_size = [[params[:page_size].to_i, 1].max, 100].min
    page_size = 100 if params[:page_size].blank?
    cursor = params[:start_cursor].presence

    return render_live(client.get_block_children(parent_id, start_cursor: cursor, page_size: page_size)) if page_id.nil?

    page = NotionPage.with_deleted.find_by!(notion_id: page_id)
    marker = parent_id == page_id ? page.root_children_fetched_at : NotionBlock.where(notion_id: parent_id).pick(:children_fetched_at)
    fresh = marker.present? && (page.blocks_stale_at.nil? || marker > page.blocks_stale_at)

    if fresh
      rows = NotionBlock.children_of(parent_id).to_a
      start = cursor ? rows.index { |r| r.notion_id == Stacks::Notion::Ids.normalize(cursor) || r.notion_id == cursor } : 0
      raise Stacks::Notion::RequestError.new(400, { "object" => "error", "status" => 400, "code" => "validation_error", "message" => "start_cursor is invalid" }) if start.nil?
      slice = rows[start, page_size] || []
      nxt = rows[start + page_size]
      return render_cached(
        { "object" => "list", "results" => slice.map(&:data), "next_cursor" => nxt&.notion_id, "has_more" => !nxt.nil?, "type" => "block", "block" => {} },
        fetched_at: marker, state: "hit"
      )
    end

    live = client.get_block_children(parent_id, start_cursor: cursor, page_size: 100)
    # Positions written here by a single-page fill are provisional: replace_level
    # rewrites them from 0 when the level is completed, and children_of is only
    # ever read back on a fresh (completed) level.
    offset = cursor ? NotionBlock.where(parent_id: parent_id).count : 0
    # A malformed response (has_more absent/true but next_cursor nil, or vice
    # versa) must never stamp a level complete and trigger replace_level's deletes.
    if cursor.nil? && live["has_more"] == false && live["next_cursor"].nil?
      Stacks::Notion::Mirror.replace_level(parent_id: parent_id, page_id: page_id, blocks: live["results"], fetched_at: Time.current)
    else
      Stacks::Notion::Mirror.store_blocks(parent_id: parent_id, page_id: page_id, blocks: live["results"], position_offset: offset)
    end
    response.set_header("X-Stacks-Cache", marker.present? ? "stale" : "miss")
    response.set_header("X-Stacks-Fetched-At", Time.current.utc.iso8601)
    render json: live, status: 200
  end

  # ---- lists: always live; results warm the cache --------------------------
  def query_data_source
    id = normalized_id!
    live = client.query_data_source(id, json_body)
    upsert_results(live["results"])
    render_live(live)
  end

  def search
    live = client.search(json_body)
    upsert_results(live["results"])
    render_live(live)
  end

  # ---- writes: live, then invalidate ---------------------------------------
  def create_page
    obj = client.create_page(json_body)
    Stacks::Notion::Mirror.upsert_page(obj)
    render_live(obj)
  end

  def update_page
    obj = client.update_page(normalized_id!, json_body)
    Stacks::Notion::Mirror.upsert_page(obj)
    render_live(obj)
  end

  def append_block_children
    parent_id = Stacks::Notion::Ids.normalize(params[:id]) || params[:id].to_s
    live = client.append_block_children(parent_id, json_body)
    mark_page_stale(parent_id)
    render_live(live)
  end

  def update_block
    block_id = Stacks::Notion::Ids.normalize(params[:id]) || params[:id].to_s
    obj = client.update_block(block_id, json_body)
    mark_page_stale(block_id, obj)
    render_live(obj)
  end

  def delete_block
    block_id = Stacks::Notion::Ids.normalize(params[:id]) || params[:id].to_s
    obj = client.delete_block(block_id)
    mark_page_stale(block_id, obj)
    render_live(obj)
  end

  def not_found
    notion_error(404, "object_not_found", "Could not find route #{request.method} #{request.path}")
  end

  private

  def client
    @client ||= Stacks::Notion.new(max_retries: 1, retry_after_cap: 6)
  end

  def require_api_key!
    provided = request.headers["X-Api-Key"].to_s
    expected = Stacks::Utils.config.dig(:stacks, :private_api_key).to_s
    return if expected.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected)

    notion_error(401, "unauthorized", "API token is invalid.")
  end

  def normalized_id!
    Stacks::Notion::Ids.normalize(params[:id]) or
      raise Stacks::Notion::RequestError.new(400, { "object" => "error", "status" => 400, "code" => "validation_error", "message" => "path.id should be a valid uuid, instead was `#{params[:id]}`." })
  end

  def json_body
    request.body.rewind
    raw = request.body.read
    raw.blank? ? {} : JSON.parse(raw)
  rescue JSON::ParserError
    raise Stacks::Notion::RequestError.new(400, { "object" => "error", "status" => 400, "code" => "invalid_json", "message" => "Error parsing JSON body." })
  end

  def render_cached(body, fetched_at:, state:)
    response.set_header("X-Stacks-Cache", state)
    response.set_header("X-Stacks-Fetched-At", fetched_at.utc.iso8601) if fetched_at
    render json: body, status: 200
  end

  def render_live(body, status: 200)
    response.set_header("X-Stacks-Cache", "live")
    render json: body, status: status
  end

  def notion_error(status, code, message)
    render json: { "object" => "error", "status" => status, "code" => code, "message" => message }, status: status
  end

  def render_notion_error(err)
    # 4xx from Notion is the caller's problem and passes through silently; a 5xx
    # that survived the client's retries or a 401 (revoked integration token) is
    # ours to know about.
    Sentry.capture_exception(err) if defined?(Sentry) && (err.code >= 500 || err.code == 401)
    response.set_header("Retry-After", err.headers["retry-after"]) if err.headers["retry-after"].present?
    render json: err.body, status: err.code
  end

  # 403/404 from Notion on a page we track: remember that we lost it, then re-raise.
  def with_access_tracking(scope)
    yield
  rescue Stacks::Notion::RequestError => e
    scope.update_all(access_lost: true) if [403, 404].include?(e.code)
    raise
  end

  def upsert_results(results)
    Array(results).each do |obj|
      case obj["object"]
      when "page" then Stacks::Notion::Mirror.upsert_page(obj)
      when "data_source" then Stacks::Notion::Mirror.upsert_data_source(obj)
      end
    end
  end

  # The owning page of a block id: a cached page/block, or the parent the
  # response reports. Unknown → nothing to invalidate.
  def mark_page_stale(block_or_page_id, obj = nil)
    page_id = Stacks::Notion::Mirror.owning_page_id(block_or_page_id)
    page_id ||= Stacks::Notion::Mirror.owning_page_id(obj.dig("parent", "page_id") || obj.dig("parent", "block_id")) if obj
    return unless page_id
    NotionPage.with_deleted.where(notion_id: page_id).update_all(blocks_stale_at: Time.current)
  end
end
