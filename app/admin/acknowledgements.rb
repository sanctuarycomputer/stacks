ActiveAdmin.register Acknowledgement do
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :edit, :update
  permit_params :name, :learn_more_url, :acknowledgement_type
  menu false

  index download_links: false do
    column :name
    column :learn_more_url
    column :acknowledgment_type
    actions
  end
end
