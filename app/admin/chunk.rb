ActiveAdmin.register Chunk do
  # Reached by drilling into a Document (not a top-level menu item).
  menu false
  actions :index, :show

  # Only Hugh can reach these pages — blocks direct URL navigation.
  controller do
    before_action do
      unless current_admin_user&.can_access_etl_admin?
        redirect_to admin_root_path, alert: "You are not authorized to view that page."
      end
    end
  end

  filter :speaker_name

  index do
    id_column
    column :document
    column :position
    column :speaker_name
    column :content
    actions
  end
end
