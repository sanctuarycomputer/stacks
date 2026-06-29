ActiveAdmin.register Chunk do
  # Reached by drilling into a Document (not a top-level menu item).
  menu false
  actions :index, :show

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
