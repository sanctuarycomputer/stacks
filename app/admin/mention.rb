ActiveAdmin.register Mention do
  # Reached by drilling into a Document/Chunk (not a top-level menu item).
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

  scope('Unresolved') { |s| s.unresolved }
  scope :all

  filter :raw_text
  filter :status

  index do
    id_column
    column :chunk
    column :raw_text
    column :status
    column :contact
    actions
  end

  member_action :resolve, method: :put do
    resource.update!(contact_id: params[:contact_id], status: :resolved)
    redirect_to admin_mentions_path, notice: 'Mention resolved'
  end
end
