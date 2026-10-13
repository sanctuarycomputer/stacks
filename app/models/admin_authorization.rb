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

  # Executive compensation. MsoRolePeriod has its own line below.
  MSO_COMPENSATION_CLASSES = [MsoTrueup, MsoSnapshot].freeze

  # Narrows index pages. An admin sees everything. Everyone else never sees
  # garden3d's invoice passes or the trackers on them (see authorized?).
  # Beyond that, (actual or granted) leads see everything, and users whose
  # only access comes from project-scoped "lead" grants see their own
  # projects. ActiveAdmin calls this automatically for every index, in every
  # format, via apply_authorization_scope.
  def scope_collection(collection, action = :read)
    return collection if user.is_admin?

    # ActiveAdmin calls scope_collection with whatever scoped_collection
    # returns. Resources that override scoped_collection (e.g. InvoicePass)
    # hand us an ActiveRecord::Relation, but top-level resources fall back to
    # InheritedResources' end_of_association_chain, which for a bare model
    # (no association scoping applied yet) is the model Class itself — and a
    # Class doesn't respond to #klass. Resolve to the actual model class
    # either way rather than assuming a Relation.
    model = collection.respond_to?(:klass) ? collection.klass : collection

    collection = without_garden3d_passes(collection, model)
    return collection if user.can_act_as_lead?

    scoped_ids = user.lead_scoped_project_tracker_ids
    return collection if scoped_ids.empty?

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

    # Deleting a founder true-up deletes its QuickBooks bill in that company's
    # books (Trueup's before_destroy), and for a month the MSO pays the
    # nightly sync will not write it again. Must stay above the blanket lead
    # grant; ActiveAdmin hides the Delete control from whoever this refuses.
    if (subject.is_a?(Trueup) || subject == Trueup) && action == :destroy
      return user.is_admin?
    end

    # Opt-out sign-off polices project leads, so it must sit above the blanket
    # lead grant below — otherwise every lead could approve their own bypass.
    if subject.is_a?(ProjectCapsule) || subject == ProjectCapsule
      return user.is_admin? if [:sign_off, :revoke_sign_off].include?(action)
    end

    if subject.is_a?(ProjectSatisfactionSurvey) || subject == ProjectSatisfactionSurvey
      return user.is_admin? if [:close_survey, :reopen_survey].include?(action)
    end

    # API tokens grant machine access to write surfaces: admins only, never leads.
    return user.is_admin? if subject.is_a?(ApiToken) || subject == ApiToken

    # The MSO roster decides who is paid executive compensation: admins only,
    # for every action including read. Must stay above the blanket lead grant.
    return user.is_admin? if subject.is_a?(MsoRolePeriod) || subject == MsoRolePeriod

    # The snapshot holds fee income, the cap and every executive's line:
    # admins only. A true-up is for admins and for the executive whose ledger
    # it is on, who may read it. Class-level subjects (:index, :new, :create)
    # are admin-only, which is why MsoTrueup is NOT in OWN_LEDGER_ITEM_CLASSES.
    # Must stay above the blanket lead grant: every executive is likely to be
    # a lead, and a lead reads all.
    if MSO_COMPENSATION_CLASSES.any? { |klass| subject == klass || subject.is_a?(klass) }
      # Accepting a true-up is its owner's act alone. Checked BEFORE the admin
      # line: the executives are admins, and "an admin may accept" would let
      # each accept the other's.
      return own_mso_trueup?(subject) if action == :toggle_acceptance
      return true if user.is_admin?
      return action == :read && own_mso_trueup?(subject)
    end

    # Computes and writes every executive's true-up: admins only, whichever
    # pass it is asked of.
    if action == :run_mso_compensation && (subject.is_a?(InvoicePass) || subject == InvoicePass)
      return user.is_admin?
    end

    # garden3d's invoice passes hold what the operating companies pay it:
    # admins only, for every action including read, on the pass and on every
    # tracker on it. The owner's decision, and it deliberately takes in the
    # seven legacy 2025 passes and their Forecast trackers. Must stay above
    # the blanket lead grant and the scoped-grantee branch below; hiding a
    # button or a row in the page enforces nothing. scope_collection keeps
    # the same rows out of the index pages.
    unless user.is_admin?
      return false if on_garden3d_pass?(subject)

      # The payouts under such a tracker follow it (only the legacy trackers
      # have any). The one thing kept: a contributor may still read their own.
      if subject.is_a?(ContributorPayout) && on_garden3d_pass?(subject.invoice_tracker)
        return action == :read && payout_owner(subject) == user
      end
    end

    # The list of Google Analytics sites Stacks syncs: admins edit it; leads may read it.
    if subject.is_a?(AnalyticsProperty) || subject == AnalyticsProperty
      return user.is_admin? unless action == :read
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
        # A scoped grantee needs passes as containers to reach their own
        # trackers. (garden3d's passes never get this far: see above.)
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
      next unless payout_owner(subject) == user
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

  private

  # Is this an invoice pass issued by garden3d, or a tracker on one?
  # InvoicePass#garden3d? is "the pass is garden3d's", legacy passes
  # included. False for a class, and for a tracker not yet on a pass.
  def on_garden3d_pass?(subject)
    case subject
    when InvoicePass, InvoiceTracker then subject.garden3d?
    else false
    end
  end

  # The admin user a ledger item pays, or nil.
  def payout_owner(subject)
    subject.contributor&.forecast_person&.admin_user
  rescue StandardError
    nil
  end

  def own_mso_trueup?(subject)
    return false unless subject.is_a?(MsoTrueup) && subject.persisted?

    owner = subject.ledger&.contributor&.forecast_person&.admin_user
    owner.present? && owner == user
  end

  # Index pages, for anyone but an admin: no garden3d pass, and no tracker on
  # one. By enterprise NAME in a subquery, so a database with no garden3d row
  # (most tests) filters nothing and raises nothing.
  def without_garden3d_passes(collection, model)
    garden3d_ids = Enterprise.where(name: Enterprise::GARDEN3D_NAME).select(:id)

    case model.name
    when "InvoicePass"
      collection.where.not(enterprise_id: garden3d_ids)
    when "InvoiceTracker"
      collection.where.not(invoice_pass_id: InvoicePass.where(enterprise_id: garden3d_ids).select(:id))
    else
      collection
    end
  end
end
