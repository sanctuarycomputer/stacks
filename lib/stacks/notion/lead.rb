class Stacks::Notion::Lead < Stacks::Notion::Base
  class << self
    def all
      NotionPage.where(
        notion_parent_type: "database_id",
        notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS])
      ).map(&:as_lead)
    end
  end

  def studios
    all_studios = Studio.all_studios
    matches = (get_prop_value("studio") || []).map{|s| s["name"]}.intersection(all_studios.map(&:name))
    matches.map{|m| all_studios.find{|s| s.name == m}}
  end

  def received_at
    get_prop_value("✨ Lead Received").dig("start")
  end

  def reactivate_at
    get_prop_value("Reactivate Date").dig("start")
  end

  def age
    return nil unless received_at.present?
    (Date.today - Date.parse(received_at)).to_i
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

