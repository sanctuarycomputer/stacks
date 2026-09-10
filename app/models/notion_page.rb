class NotionPage < ApplicationRecord
  acts_as_paranoid

  # Rows of a Notion database, by dashed database id. in_trash rows are kept
  # (served one-to-one by the proxy) but are not "in" the database for Stacks.
  scope :for_database, ->(dashed_database_id) { where(database_id: dashed_database_id, in_trash: false) }

  scope :lead, -> { for_database(Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])) }
  scope :human_operating_manual, -> { for_database(Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:HUMAN_OPERATING_MANUALS])) }

  def as_lead
    Stacks::Notion::Lead.new(self)
  end

  def as_human_operating_manual
    Stacks::Notion::HumanOperatingManual.new(self)
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

  # Notion's created_time when present; nil otherwise (notion_pages has no
  # created_at column, so there is nothing to fall back to).
  def created_at
    created_time = data.is_a?(Hash) ? data["created_time"] : nil
    created_time.present? ? DateTime.parse(created_time) : nil
  end
end
