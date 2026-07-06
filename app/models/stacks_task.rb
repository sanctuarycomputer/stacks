class StacksTask
  attr_reader :type, :subject, :owners

  # Explicit labels for every issue type. Pattern: "<subject> <action phrase>"
  # so the issue is unambiguous on its own without context from a column header.
  # Add new types here when adding new discoveries.
  HUMANIZED_TYPES = {
    # ProjectTracker issues
    project_capsule_incomplete: "Project capsule needs completion",
    likely_should_mark_as_work_complete?: "Project tracker likely needs to be marked as work complete",
    no_project_lead_set: "Project tracker needs project lead assigned",
    no_account_lead_set: "Project tracker needs account lead assigned",

    # ForecastProject issues
    needs_archiving: "Forecast project needs archiving",
    no_explicit_hourly_rate_set: "Forecast project needs explicit hourly rate",
    multiple_hourly_rates_set: "Forecast project has conflicting hourly rates",
    not_linked_to_project_tracker: "Forecast project not linked to a project tracker",

    # ForecastPerson issues
    no_studio_in_forecast: "Forecast person needs studio assignment",
    multiple_studios_in_forecast: "Forecast person has multiple studio assignments",

    # ForecastAssignment issues
    date_in_future: "Forecast assignment dated in the future",
    allocation_needs_rounding_to_nearest_minute: "Forecast assignment allocation needs rounding to whole minute",

    # AdminUser issues
    no_full_time_periods_set: "Admin user needs full-time periods set",
    missing_skill_tree: "Admin user needs skill tree set",

    # Reimbursement issues
    pending_acceptance: "Reimbursement needs acceptance",

    # Notion lead issues
    no_received_at_timestamp_set: "Notion lead needs received-at timestamp",
    needs_settling: "Notion lead needs settling",
    no_studios_set: "Notion lead needs studios assigned",

    # Survey issues
    survey: "Studio survey response required",
    project_satisfaction_survey: "Project satisfaction survey response required",

    # PayCycle issues
    pay_cycle_needs_approval: "Pay cycle needs your approval on behalf of your team",

    # Ledger issues
    missing_qbo_vendor_for_contributor: "Contributor needs a QBO vendor for this enterprise's ledger",
    legacy_ledger_needs_qbo_migration: "Legacy ledger needs migration to QBO-bound",
    auto_paused_recurring_on_qbo_bound: "Recurring deduction auto-paused on QBO-bound ledger (would never deduct)",

  }.freeze

  # type    — Symbol classifying the task (:project_capsule_incomplete, :survey, …)
  # subject — the AR record the task is about (a ProjectTracker, Survey, etc.)
  # owners  — Array of AdminUsers who can act on the task. MUST contain at least
  #           one user; routing rules guarantee a fallback to AdminUser.admin
  #           when no natural owner exists.
  def initialize(type:, subject:, owners:)
    @type = type.to_sym
    @subject = subject
    @owners = Array(owners).compact.uniq
    raise ArgumentError, "StacksTask requires at least one owner (subject=#{subject.inspect}, type=#{type.inspect})" if @owners.empty?
    freeze
  end

  def assigned_to?(admin_user)
    return false if admin_user.nil?
    owners.include?(admin_user)
  end

  def humanized_type
    HUMANIZED_TYPES[type] || type.to_s.humanize
  end

  # Stable identifier for the subject's class — used in URL params (?data_type=…)
  # and as the human-readable section label. Demodulizes namespaced classes so
  # we don't get "stacks/notion/leads"; explicit overrides preserve context that
  # would otherwise be lost when demodulizing (e.g. Stacks::Notion::Lead → "leads").
  def subject_class_key
    case subject
    when Stacks::Notion::Lead then "notion_leads"
    else subject.class.name.demodulize.underscore.pluralize
    end
  end

  # Display name shown in the Subject column — chosen per-class so each subject
  # reads as something a person can recognize (project name, lead title, contributor
  # email, etc.) rather than a generic Object#to_s.
  #
  # redact_amounts: true omits compensation-adjacent figures (reimbursement
  # details, contributor ledger adjustment amounts) and gives unknown subject
  # types a conservative generic name. Operational free-text (project names,
  # survey titles, lead titles) passes through — those are business data the
  # MCP layer exposes elsewhere by design.
  def subject_display_name(redact_amounts: false)
    case subject
    when ProjectTracker then subject.name.presence || "Project Tracker ##{subject.id}"
    when ForecastProject then subject.try(:display_name).presence || subject.name.presence || "Forecast Project ##{subject.forecast_id}"
    when ForecastPerson then subject.try(:display_name).presence || subject.try(:name).presence || subject.try(:email).presence || "Forecast Person ##{subject.forecast_id}"
    when ForecastAssignment then subject.try(:name).presence || "Forecast Assignment ##{subject.forecast_id}"
    when AdminUser then subject.email
    when Reimbursement
      if redact_amounts
        "Reimbursement ##{subject.id}"
      else
        (subject.try(:display_name).presence || "Reimbursement ##{subject.id}").truncate(50)
      end
    when Survey then subject.try(:title).presence || "Survey ##{subject.id}"
    when ProjectSatisfactionSurvey
      pt_name = subject.try(:project_capsule).try(:project_tracker).try(:name)
      pt_name.present? ? "#{pt_name} (satisfaction survey)" : "Project Satisfaction Survey ##{subject.id}"
    when Stacks::Notion::Lead then subject.try(:page_title).presence || "Notion Lead"
    when PayCycle then "#{subject.enterprise.name} — #{subject.starts_at.to_s(:long)} to #{subject.ends_at.to_s(:long)}"
    when Ledger then "#{subject.contributor.forecast_person&.email || "Contributor ##{subject.contributor_id}"} on #{subject.enterprise.name}"
    when RecurringLedgerAdjustment
      base = "#{subject.ledger.contributor.forecast_person&.email || "Contributor ##{subject.ledger.contributor_id}"} on #{subject.ledger.enterprise.name}"
      if redact_amounts
        "#{base} — #{subject.cadence} recurring adjustment"
      else
        "#{base} — #{subject.cadence} $#{format("%.2f", subject.amount)}"
      end
    else
      if redact_amounts
        # New monetary subject types must add an explicit redacting branch
        # above. Until they do, this conservative fallback keeps free-text
        # display names (which can embed amounts) out of redacted surfaces.
        "#{subject.class.name.demodulize.titleize} ##{subject.try(:id) || '?'}"
      else
        subject.try(:display_name).presence || subject.try(:name).presence || subject.to_s
      end
    end
  end

  # URL the user should navigate to in order to fix this task. Where the fix
  # lives outside Stacks (Forecast, Notion), an external URL is returned and
  # subject_url_external? returns true so the view can open it in a new tab.
  def subject_url
    helpers = Rails.application.routes.url_helpers
    case subject
    when ProjectTracker then helpers.admin_project_tracker_path(subject)
    when ForecastProject then subject.try(:link)
    when ForecastPerson then subject.try(:external_link)
    when ForecastAssignment then subject.try(:external_link)
    when AdminUser then helpers.admin_admin_user_path(subject)
    when Reimbursement then helpers.admin_ledger_reimbursement_path(subject.ledger, subject)
    when Survey then helpers.admin_survey_path(subject)
    when ProjectSatisfactionSurvey then helpers.admin_project_satisfaction_survey_path(subject)
    when Stacks::Notion::Lead then subject.try(:notion_link) || subject.try(:external_link)
    when PayCycle then helpers.admin_enterprise_pay_cycle_path(subject.enterprise, subject)
    when Ledger
      if type == :legacy_ledger_needs_qbo_migration
        helpers.admin_ledger_path(subject)
      else
        helpers.edit_admin_contributor_path(subject.contributor)
      end
    when RecurringLedgerAdjustment then helpers.edit_admin_recurring_ledger_adjustment_path(subject)
    else subject.try(:external_link)
    end
  end

  def subject_url_external?
    case subject
    when ForecastProject, ForecastPerson, ForecastAssignment, Stacks::Notion::Lead then true
    else false
    end
  end

  def ==(other)
    other.is_a?(StacksTask) &&
      other.type == type &&
      other.subject == subject &&
      other.owners.to_set == owners.to_set
  end
  alias_method :eql?, :==

  def hash
    [type, subject, owners.to_set].hash
  end

  # Backwards-compat with existing Hash-style consumers (`task[:type]`,
  # `task[:subject]`). Lets old views keep working without churn while we
  # migrate them; new code should use accessors.
  def [](key)
    case key.to_sym
    when :type then type
    when :subject then subject
    when :owners then owners
    end
  end
end
