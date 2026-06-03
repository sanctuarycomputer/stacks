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

  # def scope_collection(collection, action = nil)
  #   # This automatically filters the Index page
  #   if user.admin?
  #     collection
  #   else
  #     # Ensure users only see records they own
  #     # This assumes the model has a user_id or similar relation
  #     collection.where(user_id: user.id)
  #   end
  # end

  def authorized?(action, subject = nil)
    if subject.is_a?(ContributorAdjustment) || subject == ContributorAdjustment
      return user.is_admin? if [:create, :update, :destroy].include?(action)
    end

    if (subject.is_a?(ProjectSatisfactionSurvey) || subject == ProjectSatisfactionSurvey) && action == :destroy
      return user.is_admin?
    end

    return true if (user.is_admin? || user.has_led_projects?)

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
