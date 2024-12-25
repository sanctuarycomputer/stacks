ActiveAdmin.register ZenhubWorkspace do
  menu label: "Zenhub Workspaces", parent: "Github & Zenhub"
  config.filters = true
  config.paginate = false
  actions :index, :show

  index download_links: false do
    column :name
    actions
  end
end
