# One-to-one caching reverse proxy of Notion's REST API. Same paths, bodies and
# responses as api.notion.com; cache hits never touch Notion; misses fill through
# Stacks::Notion (paced). Spec: docs/superpowers/specs/2026-09-10-notion-mirror-design.md
class Api::Notion::ProxyController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :require_api_key!

  # Child rescue_from wins over ApiController's blanket StandardError handler:
  # Notion's own error is passed through, untouched and without Sentry.
  rescue_from Stacks::Notion::RequestError, with: :render_notion_error

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
    id = normalized_id!
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

  # Tasks 8 and 9 replace these bodies.
  def get_block_children = not_found
  def query_data_source = not_found
  def search = not_found
  def create_page = not_found
  def update_page = not_found
  def append_block_children = not_found
  def update_block = not_found
  def delete_block = not_found

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
end
