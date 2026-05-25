class ApplicationController < ActionController::Base
  def root
  end

  def true_admin_user
    @_true_admin_user ||= warden.user(:admin_user)
  end

  def current_admin_user
    if session[:impersonated_admin_user_id].present?
      @_impersonated_admin_user ||= AdminUser.find_by(id: session[:impersonated_admin_user_id])
      return @_impersonated_admin_user if @_impersonated_admin_user.present?
      session.delete(:impersonated_admin_user_id)
    end
    true_admin_user
  end

  def impersonating?
    session[:impersonated_admin_user_id].present? && true_admin_user&.id != session[:impersonated_admin_user_id]
  end
  helper_method :true_admin_user, :impersonating?

  def toggle_accounting_method
    if session[:accounting_method].nil?
      session[:accounting_method] = "accrual"
    else
      if session[:accounting_method] == "cash"
        session[:accounting_method] = "accrual"
      elsif session[:accounting_method] == "accrual"
        session[:accounting_method] = "cash"
      else
        session[:accounting_method] = "cash"
      end
    end
    redirect_back(fallback_location: root_path)
  end
end
