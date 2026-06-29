ActiveAdmin.register Chunk do
  menu parent: 'MCP', label: 'ETL: Chunks'
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
