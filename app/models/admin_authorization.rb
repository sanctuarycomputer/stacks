class AdminAuthorization < ActiveAdmin::AuthorizationAdapter
  def authorized?(action, subject = nil)
    case subject
    when normalized(AdminUser)
      if action == :update
        subject == user || user.is_admin?
      else
        true
      end
    when normalized(Survey)
      if action == :update
        user.is_admin?
      else
        true
      end
    when normalized(ProfitSharePass)
      if action == :update
        user.is_admin?
      else
        true
      end
    else
      true
    end
  end
end
