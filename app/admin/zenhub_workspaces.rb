ActiveAdmin.register ZenhubWorkspace do
  menu label: "Zenhub Workspaces", parent: "Github & Zenhub"
  config.filters = true
  config.paginate = false
  actions :index, :show

  action_item :issues, only: :show do
    link_to("Zenhub Issues ↗", admin_zenhub_workspace_zenhub_issues_path(resource))
  end

  index download_links: false do
    column :name do |workspace|
      link_to(workspace.name, workspace.html_url, rel: "noopener noreferrer", target: "_blank")
    end

    column :total_issues do |workspace|
      workspace.zenhub_issues.count
    end

    column :total_story_points

    column :github_repos

    actions defaults: false do |workspace|
      text_node link_to("Zenhub Issues ↗", admin_zenhub_workspace_zenhub_issues_path(workspace))
    end
  end
end
