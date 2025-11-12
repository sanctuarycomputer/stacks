ActiveAdmin.register TeamLeadPeriod do
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :edit, :update, :destroy
  permit_params :project_tracker_id, :admin_user_id, :started_at, :ended_at
  menu false

  config.sort_order = 'started_at_desc'

  belongs_to :project_tracker

  index download_links: false do
    column :project_tracker
    column :admin_user
    column :started_at
    column :ended_at
    actions
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :project_tracker, input_html: { disabled: true }
      f.input :admin_user, collection: AdminUser.candidates_for_role
      f.input :started_at, as: :date_select, hint: "Leave blank to default to the date of the first recorded hour"
      f.input :ended_at, as: :date_select, hint: "Leave blank unless this role was passed off to another person"
    end

    f.actions
  end
end
