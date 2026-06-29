ActiveAdmin.register SourceSync do
  menu parent: 'MCP', label: 'ETL: Source syncs'
  actions :index, :show

  index do
    id_column
    column :source
    column :last_run_at
    column :status
    column(:stats) { |s| s.stats.to_json }
    actions
  end
end
