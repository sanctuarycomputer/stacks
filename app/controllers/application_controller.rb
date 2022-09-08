class ApplicationController < ActionController::Base
  def root
  end

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
