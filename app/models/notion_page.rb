class NotionPage < ApplicationRecord
  has_paper_trail

  def self.where_page_title(name)
    NotionPage.find_by_sql("
      SELECT *
      FROM notion_pages,
          LATERAL JSONB_ARRAY_ELEMENTS(notion_pages.data -> 'properties' -> 'Name' -> 'title') name_item
      WHERE name_item ->> 'plain_text' = '#{name}'
    ")
  end

  def self.where_status(status)
    NotionPage.find_by_sql("
      SELECT *
      FROM notion_pages
      WHERE data -> 'properties' -> 'Status' -> 'select' ->> 'name' = '#{status}'
    ")
  end

  def self.status_changed_to_during_range(status, start_range, end_range)
    NotionPage.includes(:versions).all.select do |page|
      page.status_history.find do |diff|
        diff[:current_status] == status &&
        diff[:changed_at] >= start_range &&
        diff[:changed_at] <= end_range
      end.present?
    end
  end

  def get_prop(name)
    prop_type = data.dig("properties", name, "type")
    data.dig("properties", name, prop_type)
  end

  def page_title
    (data.dig("properties", "Name", "title")[0] || {}).dig("plain_text")
  end

  def status
    data.dig("properties", "Status", "select", "name")
  end

  def created_at
    DateTime.parse(data.dig("created_time"))
  end

  def status_history
    versions.map do |v|
      prev_status = v.changeset["data"][0].dig("properties", "Status", "select", "name") || v.changeset["data"][0].dig("properties", 'Stage (formerly "Status")', "select", "name")
      current_status = v.changeset["data"][1].dig("properties", "Status", "select", "name") || v.changeset["data"][1].dig("properties", 'Stage (formerly "Status")', "select", "name")

      next nil if prev_status == current_status
      {
        prev_status: prev_status,
        current_status: current_status,
        changed_at: v.created_at.to_date,
      }
    end.compact
  end
end
