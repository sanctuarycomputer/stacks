ActiveAdmin.register StudioMembership do
  belongs_to :admin_user
  permit_params :admin_user_id, :studio_id, :started_at, :ended_at
  actions :index, :new, :edit, :update, :create, :destroy
  config.filters = false
  config.paginate = false

  index download_links: false do
    column :studio
    column :current?
    column :started_at
    column :ended_at
    actions
  end
end