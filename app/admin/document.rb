ActiveAdmin.register Document do
  menu parent: 'MCP', label: 'ETL: Documents'
  actions :index, :show

  filter :source
  filter :excluded
  filter :occurred_at

  index do
    id_column
    column :source
    column :title
    column :occurred_at
    column :excluded
    column('Chunks') { |d| d.chunks.count }
    actions
  end
end
