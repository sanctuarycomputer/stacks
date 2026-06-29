ActiveAdmin.register Mention do
  # Reached by drilling into a Document/Chunk (not a top-level menu item).
  menu false
  actions :index, :show

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
