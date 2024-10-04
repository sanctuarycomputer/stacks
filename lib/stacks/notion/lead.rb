class Stacks::Notion::Lead < Stacks::Notion::Base
  class << self
    def all
      NotionPage.where(
        notion_parent_type: "database_id",
        notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEAD_DATA_TRACKING])
      ).map(&:as_lead)
    end
  end

  def received_at
    get_prop_value("✨ Lead Received").dig("start")
  end

  def settled_at
    get_prop_value("Settled Date").dig("string")
  end

  def proposal_sent_at
    get_prop_value("✨ Proposal Sent").dig("start")
  end

  def won_at
    get_prop_value("✨ Status: Won").dig("start")
  end

  def considered_successful?
    won_at.present?
  end
end

