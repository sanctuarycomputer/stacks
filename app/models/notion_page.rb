class NotionPage < ApplicationRecord
  acts_as_paranoid

  scope :lead, -> {
    where(
      notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])
    )
  }

  def as_lead
    Stacks::Notion::Lead.new(self)
  end

  def notion_link
    "https://www.notion.so/garden3d/#{notion_id.gsub('-', '')}"
  end

  def external_link
    notion_link
  end

  # For active admin to set the title on the show page
  def name
    page_title
  end

  def get_prop(name)
    prop_type = data.dig("properties", name, "type")
    data.dig("properties", name, prop_type)
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
