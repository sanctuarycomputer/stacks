ActiveAdmin.register RacialBackground do
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :edit, :update
  permit_params :name
  menu false

  index download_links: false do
    column :name
    column :members do |resource|
      AdminUserRacialBackground.where(racial_background: resource).count
    end
    actions
  end
end
