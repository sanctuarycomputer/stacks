ActiveAdmin.register RacialBackground do
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :edit, :update
  permit_params :name
  menu false

  index download_links: false do
    column :name
    actions
  end
end
