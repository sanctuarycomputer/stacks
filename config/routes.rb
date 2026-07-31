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
    resources :contacts, only: [:create, :index]
    match '/mcp', to: 'mcp#handle', via: [:post, :get, :delete]
    match '/mcp/write', to: 'mcp_write#handle', via: [:post, :get, :delete]
    resources :contributors, only: [:index]
    resources :project_trackers, only: [:index, :create] do
      resources :workstreams, only: [:create] do
        member do
          post   "rates", to: "workstreams#add_rate"
          delete "rates", to: "workstreams#remove_rate"
        end
      end
    end
    resources :recurring_assignments, only: [:create]

    namespace :v1 do
      post "projected_assignments/batch", to: "projected_assignments#batch", defaults: { format: :json }
      post "projected_assignments/adopt", to: "projected_assignments#adopt", defaults: { format: :json }
      put "projected_assignments/*source_key", to: "projected_assignments#upsert", format: false, defaults: { format: :json }
      delete "projected_assignments/*source_key", to: "projected_assignments#destroy", format: false, defaults: { format: :json }
    end
  end


end
