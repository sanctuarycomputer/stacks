class AdminAuthorization < ActiveAdmin::AuthorizationAdapter
  # Ledger-item classes a contributor is allowed to interact with on their
  # own rows. Only :update and :destroy are denied — everything else
  # (read, sync_qbo_bill, toggle_acceptance, …) is fair game because the
  # member_action's own guard re-verifies ownership.
  OWN_LEDGER_ITEM_CLASSES = [
    ContributorPayout,
    ContributorAdjustment,
    PayStub,
    ProfitShare,
    DeelInvoiceAdjustment,
  ].freeze
  OWN_LEDGER_ITEM_DENY = [:update, :destroy].freeze

  # Narrows index pages for users whose only access comes from
  # project-scoped "lead" grants. Admins and (actual or granted) leads see
  # everything. ActiveAdmin calls this automatically for every index via
  # apply_authorization_scope.
  def scope_collection(collection, action = :read)
    return collection if user.is_admin? || user.can_act_as_lead?

    scoped_ids = user.lead_scoped_project_tracker_ids
    return collection if scoped_ids.empty?

    # ActiveAdmin calls scope_collection with whatever scoped_collection
    # returns. Resources that override scoped_collection (e.g. InvoicePass)
    # hand us an ActiveRecord::Relation, but top-level resources fall back to
    # InheritedResources' end_of_association_chain, which for a bare model
    # (no association scoping applied yet) is the model Class itself — and a
    # Class doesn't respond to #klass. Resolve to the actual model class
    # either way rather than assuming a Relation.
    model = collection.respond_to?(:klass) ? collection.klass : collection

    case model.name
    when "ProjectTracker"
      collection.where(id: scoped_ids)
    when "InvoiceTracker"
      forecast_project_ids = ProjectTrackerForecastProject
        .where(project_tracker_id: scoped_ids)
        .pluck(:forecast_project_id)
      return collection.none if forecast_project_ids.empty?

      collection.where(<<~SQL.squish, forecast_project_ids)
        invoice_trackers.blueprint IS NOT NULL
        AND jsonb_typeof(invoice_trackers.blueprint -> 'lines') = 'object'
        AND EXISTS (
          SELECT 1
          FROM jsonb_each(invoice_trackers.blueprint -> 'lines') AS line
          WHERE (line.value ->> 'forecast_project')::bigint IN (?)
        )
      SQL
    else
      collection
    end
  end

  def authorized?(action, subject = nil)
    if subject.is_a?(ContributorAdjustment) || subject == ContributorAdjustment
      return user.is_admin? if [:create, :update, :destroy].include?(action)
    end

    if (subject.is_a?(ProjectSatisfactionSurvey) || subject == ProjectSatisfactionSurvey) && action == :destroy
      return user.is_admin?
    end

    return true if (user.is_admin? || user.can_act_as_lead?)

    # Project-scoped "lead" grants (leads-in-training limited to specific
    # projects): read-only visibility into the granted ProjectTrackers, the
    # InvoiceTrackers that bill them, and the InvoicePass containers needed
    # to navigate to those trackers. scope_collection narrows the index
    # pages; this handles class-level (menu/index) and per-record checks.
    if action == :read
      scoped_ids = user.lead_scoped_project_tracker_ids
      if scoped_ids.any?
        return true if [ProjectTracker, InvoiceTracker, InvoicePass].include?(subject)
        return true if subject.is_a?(InvoicePass)
        return true if subject.is_a?(ProjectTracker) && scoped_ids.include?(subject.id)
        return true if subject.is_a?(InvoiceTracker) && (subject.project_trackers.map(&:id) & scoped_ids).any?
      end
    end

    if subject.is_a?(AdminUser)
      return true if subject == user && action == :read
    end

    if subject.is_a?(Contributor)
      return true if subject.forecast_person.admin_user == user && action == :read
    end

    # For their own ledger items: allow ANY action except :update and
    # :destroy. ActiveAdmin passes custom member_action names through
    # verbatim, so enumerating each one is fragile; "anything but the
    # destructive ones" matches the intent — contributors can read /
    # accept / unaccept / sync, but can't edit fields or delete the row.
    OWN_LEDGER_ITEM_CLASSES.each do |klass|
      next unless subject == klass || subject.is_a?(klass)

      # Bare collection / non-row actions (:index, :new, :create) — subject
      # is either the class or a freshly-built instance with no ledger
      # yet. Permit any user with a contributor; controller-level filters
      # (e.g. verify_deel_invoice_access!) decide per-request.
      return true if [:index, :new, :create].include?(action) && user.forecast_person&.contributor.present?

      # Row-level actions — require ownership and deny only updates/destroys.
      owner = (subject.contributor&.forecast_person&.admin_user rescue nil)
      next unless owner == user
      return true unless OWN_LEDGER_ITEM_DENY.include?(action)
    end

    # The "Accept" button on a contributor payout POSTs to
    # InvoiceTracker#toggle_contributor_payout_acceptance. The member_action
    # itself re-checks `cp.contributor.forecast_person.admin_user ==
    # current_admin_user`, so allow the request through the adapter for any
    # contributor and let the controller filter per-CP.
    if subject.is_a?(InvoiceTracker)
      if action == :toggle_contributor_payout_acceptance && user.forecast_person&.contributor.present?
        return true
      end
    end

    if subject.is_a?(Reimbursement) || subject == Reimbursement
      if user.forecast_person&.contributor.present?
        return true if action == :create
        return true if action == :read && subject.is_a?(Reimbursement) && subject.ledger.contributor == user.forecast_person.contributor
      end
    end

    if subject.is_a?(PayCycle)
      if action == :read && user.forecast_person.present?
        contributor = user.forecast_person.contributor
        return true if contributor.present? && subject.pay_stubs.joins(:ledger).exists?(ledgers: { contributor_id: contributor.id })
      end
    end

    if subject.is_a?(ActiveAdmin::Page)
      return true if subject.name == "Dashboard"
      return true if subject.name == "All Surveys"

    end

    # Everyone can respond to & read surveys
    if subject == Survey
      return true && action == :read
    end

    if subject.is_a?(Survey)
      return true && action == :read
    end

    if subject.is_a?(SurveyResponse)
      return true && action == :create
    end

    if subject == ProjectSatisfactionSurvey
      return true && action == :read
    end

    if subject.is_a?(ProjectSatisfactionSurvey)
      return true && action == :read
    end

    if subject.is_a?(ProjectSatisfactionSurveyResponse)
      return true && action == :create
    end

    return false
  end
end
