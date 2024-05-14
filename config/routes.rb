Rails.application.routes.draw do
  root to: redirect('/admin')

  devise_config = ActiveAdmin::Devise.config
  devise_config[:controllers][:omniauth_callbacks] = 'omniauth_callbacks'
  devise_for :admin_users, devise_config

  post "/toggle_accounting_method" => "application#toggle_accounting_method", as: :admin_toggle_accounting_method
  namespace :admin do
    resource :system, only: [:show, :edit, :update]
  end
  ActiveAdmin.routes(self)

  get "/:page" => "pages#show"

  namespace :api do
    resources :profit_share_passes, only: [:index]
    resources :contacts, only: [:create]
  end
end
