class AdminAuthorization < ActiveAdmin::AuthorizationAdapter
  def authorized?(action, subject = nil)
    case subject
    when normalized(AdminUser)
      if action == :update
        subject == user || user.is_payroll_manager?
      elsif action == :read
        subject == user || user.is_payroll_manager?
      else
        true
      end
    else
      true
    end
  end
end
