ActiveAdmin.register GithubRepo do
  menu label: "Github Repos", parent: "Github & Zenhub"
  config.filters = true
  config.paginate = false
  actions :index, :show

  action_item :pull_requests, only: :show do
    link_to("Pull Requests ↗", admin_github_repo_github_pull_requests_path(resource))
  end

  index download_links: false do
    column :name do |repo|
      link_to(repo.name, repo.data["html_url"], rel: "noopener noreferrer", target: "_blank")
    end

    column :total_prs do |repo|
      repo.github_pull_requests.count
    end

    column :average_time_to_merge_in_days do |repo|
      repo.average_time_to_merge_in_days.try(:round, 2)
    end

    column :zenhub_workspaces
    column :total_estimate

    actions defaults: false do |repo|
      text_node link_to("Pull Requests ↗", admin_github_repo_github_pull_requests_path(repo))
    end
  end
end
