Rails.application.routes.draw do
  root 'application#root'

  devise_config = ActiveAdmin::Devise.config
  devise_config[:controllers][:omniauth_callbacks] = 'omniauth_callbacks'
  devise_for :admin_users, devise_config
  ActiveAdmin.routes(self)
end
