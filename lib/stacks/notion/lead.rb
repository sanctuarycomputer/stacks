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

  # Bulk-preload cache populated by callers iterating many leads. When set,
  # account_lead_admin_users resolves against this in-memory map instead of
  # firing one SQL query per lead.
  attr_accessor :account_lead_admin_users_cache

  # Downcased email strings for the Notion lead's "Account Lead" people property.
  def account_lead_emails
    raw = get_prop_value("Account Lead")
    people = raw.is_a?(Array) ? raw : []
    people.map { |p| p.dig("person", "email") || p["name"] }.compact.map(&:downcase)
  end

  # Resolves the "Account Lead" people-type property on the Notion lead row
  # to AdminUsers (matched by email). Used by Stacks::TaskBuilder to route
  # data-quality tasks on a lead (e.g. needs_settling) to its salesperson.
  # Returns an array because Notion people-properties can hold multiple
  # values; empty array means the field is unset and the caller should fall
  # back to the Stacks admin team.
  def account_lead_admin_users
    emails = account_lead_emails
    return [] if emails.empty?

    if account_lead_admin_users_cache
      emails.map { |e| account_lead_admin_users_cache[e] }.compact
    else
      AdminUser.where("LOWER(email) IN (?)", emails).to_a
    end
  end
end

