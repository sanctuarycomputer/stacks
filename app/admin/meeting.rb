ActiveAdmin.register Meeting do
  menu parent: 'MCP', label: 'ETL: Meetings', if: proc { current_admin_user&.can_access_etl_admin? }
  actions :index, :show

  # Only Hugh can reach these pages — blocks direct URL navigation, not just the menu.
  controller do
    before_action do
      unless current_admin_user&.can_access_etl_admin?
        redirect_to admin_root_path, alert: "You are not authorized to view that page."
      end
    end
  end

  filter :title
  filter :meet_source
  filter :started_at

  index do
    id_column
    column :title
    column :meet_source
    column :organizer_email
    column :started_at
    column :participant_count
    actions
  end

  show do
    attributes_table do
      row :title
      row :organizer_email
      row :started_at
      row :ended_at
      row :participant_count
      row :meet_source
    end
    panel 'Transcript segments' do
      table_for meeting.segments.order(:position) do
        column(:position)
        column(:speaker_name)
        column(:text)
      end
    end
  end
end
