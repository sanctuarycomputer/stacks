module Mcp
  # Mirrors Notion MCP's `notion-fetch`: one page as markdown, from the Stacks
  # mirror. Walks the block tree under a wall-clock deadline; `truncated: true`
  # means call again (the walk resumes) or wait for the next sweep.
  class NotionFetchTool < MCP::Tool
    DEADLINE = 6.0

    tool_name 'notion-fetch'
    description 'Fetch a Notion page (title, properties, markdown body) from the Stacks Notion mirror. truncated=true means call again to finish loading.'
    input_schema(properties: { id: { type: 'string', description: 'Notion page id or URL id (dashed or not)' } }, required: ['id'])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(id:, server_context:)
      page_id = Stacks::Notion::Ids.normalize(id)
      return Responses.error("invalid Notion id: #{id}") unless page_id

      client = Stacks::Notion.new(max_retries: 1, retry_after_cap: 6)
      result = Stacks::Notion::TreeFetcher.new(client, deadline: DEADLINE).walk(page_id)
      page = NotionPage.with_deleted.find_by!(notion_id: page_id)
      Responses.ok(
        id: page.notion_id, title: page.page_title, url: page.url,
        last_edited_time: page.notion_last_edited_at&.utc&.iso8601,
        properties: page.data["properties"] || {},
        markdown: Stacks::Notion::Markdown.render(page_id),
        truncated: !result[:complete],
        fetched_at: page.page_fetched_at&.utc&.iso8601
      )
    rescue Stacks::Notion::RequestError => e
      Responses.error("Notion #{e.code} #{e.body['code']}: #{e.body['message']}")
    end
  end
end
