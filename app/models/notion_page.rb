class NotionPage < ApplicationRecord
  has_paper_trail

  scope :milestones, -> {
    where(
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:MILESTONES])
    )
  }

  scope :biz_plan_2024_milestones, -> {
    milestones.where("page_title LIKE ?", "In 2024,%")
  }

  def self.stale_tasks
    where(
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:TASKS])
    ).all.select do |task|
      next false if task.status.downcase.include?("let go")
      next false if task.status.downcase.include?("done")
      due_date = task.data.dig("properties", "✳️ Due Date 🗓", "date", "end") || task.data.dig("properties", "✳️ Due Date 🗓", "date", "start")
      next false if due_date.nil?
      Date.parse(due_date) < Date.today
    end.sort_by do |task|
      due_date = task.data.dig("properties", "✳️ Due Date 🗓", "date", "end") || task.data.dig("properties", "✳️ Due Date 🗓", "date", "start")
      Date.parse(due_date)
    end
  end

  def notion_link
    "https://www.notion.so/garden3d/#{notion_id.gsub('-', '')}"
  end

  # For active admin to set the title on the show page
  def name
    page_title
  end

  def self.where_page_title(name)
    NotionPage.where(page_title: name)
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

  def status
    if notion_parent_id == Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:MILESTONES])
      data.dig("properties", "✳️ Status (New)", "status", "name")
    elsif Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:TASKS])
      data.dig("properties", "✳️ Status 🚦", "status", "name")
    else
      data.dig("properties", "Status", "select", "name")
    end
  end

  def created_at
    DateTime.parse(data.dig("created_time"))
  end

  def status_history
    original = versions.first&.reify || self

    versions.reduce([{
      original_status: original.status,
      changed_at: original.created_at.to_date,
    }]) do |acc, v|
      prev_status = ""
      current_status = ""

      # The initial accumaltor handles the original state
      next acc if v.event == "create"

      # If data didn't change, ignore
      next acc if v.changeset["data"].nil?

      # Data changed, so let's check if status changed
      if notion_parent_id == Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:TASKS])
        prev_status = v.changeset["data"][0].dig("properties", "✳️ Status 🚦", "status", "name")
        current_status = v.changeset["data"][1].dig("properties", "✳️ Status 🚦", "status", "name")
      else
        prev_status = v.changeset["data"][0].dig("properties", "Status", "select", "name") || v.changeset["data"][0].dig("properties", 'Stage (formerly "Status")', "select", "name")
        current_status = v.changeset["data"][1].dig("properties", "Status", "select", "name") || v.changeset["data"][1].dig("properties", 'Stage (formerly "Status")', "select", "name")
      end

      # Only stash this version if status actually changed
      if prev_status != current_status
        acc = [*acc, {
          prev_status: prev_status,
          current_status: current_status,
          changed_at: v.created_at.to_date,
        }]
      end

      acc
    end
  end
end
