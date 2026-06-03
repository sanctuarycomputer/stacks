class AdminAuthorization < ActiveAdmin::AuthorizationAdapter
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

    # For their own ledger items: ActiveAdmin passes member_action names
    # through verbatim (NOT mapped to :update by ACTIONS_DICTIONARY), so we
    # have to whitelist each action symbol explicitly. The controller-level
    # guards in each member_action stay the source of truth for "can this
    # user actually flip this row" — these adapter rules only have to let
    # the request reach the controller.
    if subject.is_a?(ContributorPayout)
      return true if subject.contributor.forecast_person.admin_user == user && action == :read
    end

    if subject.is_a?(ContributorAdjustment)
      return true if subject.contributor.forecast_person.admin_user == user && action == :read
    end

    if subject.is_a?(PayStub)
      if subject.contributor.forecast_person.admin_user == user
        return true if [:read, :toggle_acceptance].include?(action)
      end
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
