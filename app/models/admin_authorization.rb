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

    if subject.is_a?(ContributorPayout)
      return true if subject.contributor.forecast_person.admin_user == user && action == :read
    end

    if subject.is_a?(ContributorAdjustment)
      return true if subject.contributor.forecast_person.admin_user == user && action == :read
    end

    if subject.is_a?(PayStub)
      if subject.contributor.forecast_person.admin_user == user
        # Their own stub: read it AND accept/unaccept it. The toggle_acceptance
        # member_action is a POST that ActiveAdmin authorizes as :update.
        return true if [:read, :update].include?(action)
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
