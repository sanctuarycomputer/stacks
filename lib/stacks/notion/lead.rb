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
    date_start("✨ Lead Received")
  end

  def reactivate_at
    date_start("Reactivate Date")
  end

  def age
    return nil unless received_at.present?
    (Date.today - Date.parse(received_at)).to_i
  end

  def settled_at
    get_prop_value("Settled Date").dig("string")
  end

  def proposal_sent_at
    date_start("✨ Proposal Sent")
  end

  def won_at
    date_start("✨ Status: Won")
  end

  def lost_at
    date_start("✨ Status: Lost")
  end

  # Notion sends an empty date property as {"date": nil}, so the prop value is
  # nil, not a Hash. Read every date through here so one blank date can't
  # raise and take the whole NotionLeads discovery down with it.
  def date_start(prop)
    value = get_prop_value(prop)
    value.is_a?(Hash) ? value["start"] : nil
  end

  def no_proposal_sent?
    get_prop_value("✨ No Proposal Sent?") == true
  end

  # True once a Loss Surveys list response is linked to this lead (the form's
  # "(Internal) Lead" relation, mirrored as the lead's "Loss Survey" relation).
  def loss_survey_linked?
    value = get_prop_value("Loss Survey")
    value.is_a?(Array) && value.any?
  end

  # "Sent" or "Not sending" once the Account Lead has dealt with the survey;
  # nil while it is still owed. A response can take weeks, so sending is what
  # clears the task, not the reply.
  LOSS_SURVEY_DONE_STATUSES = ["Sent", "Not sending"].freeze

  def loss_survey_status
    value = get_prop_value("Loss Survey Status")
    value.is_a?(Hash) ? value["name"] : nil
  end

  def loss_survey_handled?
    loss_survey_linked? || LOSS_SURVEY_DONE_STATUSES.include?(loss_survey_status)
  end

  def considered_successful?
    won_at.present?
  end

  # Current-status is the source of truth for "open pipeline". The terminal
  # date stamps (✨ Status: Won/Lost/Ghosted) are missing on most dead leads,
  # so they must not be used to decide openness.
  OPEN_STATUSES = ["Active", "Not started", "On hold (re-engage)"].freeze

  def lead_status
    (get_prop_value("Lead Status") || {}).dig("name")
  end

  def open?
    OPEN_STATUSES.include?(lead_status)
  end

  # Midpoint of the Est. Budget Low/High Notion number props; a single value
  # if only one is filled; nil when unbudgeted (callers treat nil as $0 and
  # file a needs_budget_estimate task).
  def estimated_budget
    values = [
      get_prop_value("Est. Budget Low"),
      get_prop_value("Est. Budget High")
    ].select { |v| v.is_a?(Numeric) }
    return nil if values.empty?
    values.sum / values.length.to_f
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

