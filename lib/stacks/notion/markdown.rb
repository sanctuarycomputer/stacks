# lib/stacks/notion/markdown.rb
# Block tree → markdown. Deterministic; the only renderer in the mirror, used by
# the notion-fetch MCP tool. The REST proxy never renders anything.
module Stacks::Notion::Markdown
  FLATTEN = %w[column_list column synced_block].freeze
  SKIP = %w[table_of_contents breadcrumb].freeze
  LIST_TYPES = %w[bulleted_list_item numbered_list_item to_do].freeze

  class << self
    def render(page_id)
      page_id = Stacks::Notion::Ids.normalize(page_id) || page_id
      rows = NotionBlock.where(page_id: page_id).order(:position)
      by_parent = rows.group_by(&:parent_id).transform_values { |rs| rs.map(&:data) }
      render_blocks(by_parent, page_id)
    end

    def render_blocks(by_parent, root_id)
      out = []
      render_children(by_parent, root_id, 0, out)
      text = out.join("\n").gsub(/\n{3,}/, "\n\n").strip
      text.empty? ? "" : text + "\n"
    end

    private

    def render_children(by_parent, parent_id, depth, out)
      blocks = by_parent[parent_id] || []
      numbered = 0
      blocks.each_with_index do |b, i|
        type = b["type"]
        numbered = type == "numbered_list_item" ? numbered + 1 : 0
        lines = render_block(by_parent, b, depth, numbered)
        next if lines.nil?
        out.concat(lines)
        nxt = blocks[i + 1]
        # No blank line inside a run of list items; one after everything else.
        next if LIST_TYPES.include?(type) && nxt && LIST_TYPES.include?(nxt["type"])
        out << ""
      end
    end

    def render_block(by_parent, b, depth, numbered)
      type = b["type"]
      body = b[type] || {}
      indent = "  " * depth
      text = rich(body["rich_text"])
      case type
      when *SKIP then nil
      when *FLATTEN
        sub = []
        render_children(by_parent, b["id"], depth, sub)
        sub
      when "paragraph" then [indent + text]
      when "heading_1" then [indent + "# " + text]
      when "heading_2" then [indent + "## " + text]
      when "heading_3" then [indent + "### " + text]
      when "quote" then [indent + "> " + text]
      when "callout"
        icon = body.dig("icon", "emoji")
        [indent + "> " + [icon, text].compact.join(" ")]
      when "bulleted_list_item" then [indent + "- " + text] + nested(by_parent, b, depth)
      when "numbered_list_item" then [indent + "#{numbered}. " + text] + nested(by_parent, b, depth)
      when "to_do" then [indent + (body["checked"] ? "- [x] " : "- [ ] ") + text] + nested(by_parent, b, depth)
      when "toggle" then [indent + "▸ " + text] + nested(by_parent, b, depth)
      when "code"
        lang = body["language"].to_s
        [indent + "```" + lang, indent + text, indent + "```"]
      when "divider" then [indent + "---"]
      when "child_page" then [indent + "[#{body['title']}](notion://page/#{b['id']})"]
      when "child_database" then [indent + "[#{body['title']}](notion://database/#{b['id']})"]
      when "link_to_page"
        target = body["page_id"] || body["database_id"]
        [indent + "[page](notion://page/#{target})"]
      when "image", "file", "pdf", "video", "bookmark", "embed"
        url = body.dig("external", "url") || body.dig("file", "url") || body["url"]
        caption = rich(body["caption"])
        [indent + "![#{caption.presence || type}](#{url})"]
      when "table"
        rows = (by_parent[b["id"]] || []).map { |r| (r.dig("table_row", "cells") || []).map { |cell| rich(cell) } }
        return [] if rows.empty?
        width = rows.map(&:length).max
        header = body["has_column_header"] ? rows.shift : Array.new(width, "")
        lines = [indent + "| " + header.join(" | ") + " |", indent + "| " + Array.new(width, "---").join(" | ") + " |"]
        lines + rows.map { |r| indent + "| " + r.join(" | ") + " |" }
      else
        [indent + "<!-- unsupported: #{type} -->"]
      end
    end

    def nested(by_parent, b, depth)
      return [] unless b["has_children"]
      sub = []
      render_children(by_parent, b["id"], depth + 1, sub)
      sub.reject(&:empty?)
    end

    def rich(runs)
      Array(runs).map do |r|
        t = r["plain_text"].to_s
        a = r["annotations"] || {}
        t = "`#{t}`" if a["code"]
        t = "**#{t}**" if a["bold"]
        t = "*#{t}*" if a["italic"]
        t = "~~#{t}~~" if a["strikethrough"]
        r["href"] ? "[#{t}](#{r['href']})" : t
      end.join
    end
  end
end
