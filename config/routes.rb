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

    # One-to-one caching reverse proxy of Notion's REST API.
    # Spec: docs/superpowers/specs/2026-09-10-notion-mirror-design.md
    scope "notion/v1", module: "notion", as: "notion", defaults: { format: :json } do
      get    "pages/:id",            to: "proxy#get_page"
      get    "blocks/:id",           to: "proxy#get_block"
      get    "blocks/:id/children",  to: "proxy#get_block_children"
      get    "data_sources/:id",     to: "proxy#get_data_source"
      get    "databases/:id",        to: "proxy#get_database"
      post   "data_sources/:id/query", to: "proxy#query_data_source"
      post   "search",               to: "proxy#search"
      post   "pages",                to: "proxy#create_page"
      patch  "pages/:id",            to: "proxy#update_page"
      patch  "blocks/:id/children",  to: "proxy#append_block_children"
      patch  "blocks/:id",           to: "proxy#update_block"
      delete "blocks/:id",           to: "proxy#delete_block"
      match  "*path",                to: "proxy#not_found", via: :all
    end

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
