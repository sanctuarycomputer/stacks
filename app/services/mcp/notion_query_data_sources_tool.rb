module Mcp
  # Mirrors Notion MCP's `notion-query-data-sources` with REST-shaped arguments:
  # the filter/sorts are Notion's own JSON, passed through verbatim (live, paced).
  class NotionQueryDataSourcesTool < MCP::Tool
    tool_name 'notion-query-data-sources'
    description 'Query a Notion data source with Notion-style filter/sorts (POST /v1/data_sources/:id/query, live, paced). Returns Notion\'s list envelope.'
    input_schema(
      properties: {
        data_source_id: { type: 'string' },
        filter: { type: 'object' },
        sorts: { type: 'array' },
        page_size: { type: 'integer', description: '1-100, default 100' },
        start_cursor: { type: 'string' }
      },
      required: ['data_source_id']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(data_source_id:, filter: nil, sorts: nil, page_size: 100, start_cursor: nil, server_context:)
      ds_id = Stacks::Notion::Ids.normalize(data_source_id)
      return Responses.error("invalid data source id: #{data_source_id}") unless ds_id

      body = { "page_size" => page_size.to_i.clamp(1, 100) }
      body["filter"] = filter if filter.present?
      body["sorts"] = sorts if sorts.present?
      body["start_cursor"] = start_cursor if start_cursor.present?
      live = Stacks::Notion.new(max_retries: 1, retry_after_cap: 6).query_data_source(ds_id, body)
      Array(live["results"]).each { |obj| Stacks::Notion::Mirror.upsert_page(obj) if obj["object"] == "page" }
      Responses.ok(live)
    rescue Stacks::Notion::RequestError => e
      Responses.error("Notion #{e.code} #{e.body['code']}: #{e.body['message']}")
    end
  end
end
