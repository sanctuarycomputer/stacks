module Mcp
  # Mirrors Notion MCP's `notion-search` (title search). Always live through the
  # paced client; results warm the mirror.
  class NotionSearchTool < MCP::Tool
    tool_name 'notion-search'
    description 'Search Notion page and database titles (live, paced). Returns id, title, url, last_edited_time.'
    input_schema(
      properties: {
        query: { type: 'string' },
        page_size: { type: 'integer', description: '1-100, default 10' },
        filter: { type: 'object', description: 'Notion search filter, e.g. {"property":"object","value":"page"}' }
      },
      required: ['query']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(query:, page_size: 10, filter: nil, server_context:)
      body = { "query" => query, "page_size" => page_size.to_i.clamp(1, 100) }
      body["filter"] = filter if filter.present?
      live = Stacks::Notion.new(max_retries: 1, retry_after_cap: 6).search(body)
      results = Array(live["results"]).map do |obj|
        case obj["object"]
        when "page" then Stacks::Notion::Mirror.upsert_page(obj)
        when "data_source" then Stacks::Notion::Mirror.upsert_data_source(obj)
        end
        { object: obj["object"], id: obj["id"], title: Stacks::Notion::Mirror.title_of(obj), url: obj["url"], last_edited_time: obj["last_edited_time"] }
      end
      Responses.ok(results: results, next_cursor: live["next_cursor"], has_more: live["has_more"])
    rescue Stacks::Notion::RequestError => e
      Responses.error("Notion #{e.code} #{e.body['code']}: #{e.body['message']}")
    end
  end
end
