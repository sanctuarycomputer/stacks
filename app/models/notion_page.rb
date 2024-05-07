class NotionPage < ApplicationRecord
  self.primary_key = 'notion_id'
  has_paper_trail

  scope :milestones, -> {
    where(
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:MILESTONES])
    )
  }

  scope :page_title_eq, ->(page_title) { where_page_title(page_title) }

  def self.ransackable_scopes(*)
    %i(page_title_eq)
  end

  def self.where_page_title(name)
    NotionPage.where("data -> 'properties' -> 'Name' -> 'title' @> ?", [{"plain_text": name}].to_json)
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
    if notion_parent_id == Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:MILESTONES])
      data.dig("properties", "✳️ Status (New)", "status", "name")
    else
      data.dig("properties", "Status", "select", "name")
    end
  end

  def created_at
    DateTime.parse(data.dig("created_time"))
  end

  def status_history
    versions.map do |v|
      prev_status = ""
      current_status = ""
      if notion_parent_id == Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:TASKS])
        prev_status = v.changeset["data"][0].dig("properties", "✳️ Status 🚦", "status", "name")
        current_status = v.changeset["data"][1].dig("properties", "✳️ Status 🚦", "status", "name")
      else
        prev_status = v.changeset["data"][0].dig("properties", "Status", "select", "name") || v.changeset["data"][0].dig("properties", 'Stage (formerly "Status")', "select", "name")
        current_status = v.changeset["data"][1].dig("properties", "Status", "select", "name") || v.changeset["data"][1].dig("properties", 'Stage (formerly "Status")', "select", "name")
      end

      next nil if prev_status == current_status
      {
        prev_status: prev_status,
        current_status: current_status,
        changed_at: v.created_at.to_date,
      }
    end.compact
  end
end
