ActiveAdmin.register GithubPullRequest do
  menu label: "Pull Requests"
  config.filters = true
  config.paginate = true
  actions :index, :show
  belongs_to :github_repo

  scope :all, default: true
  scope :merged

  index download_links: false do
    column :title do |pr|
      link_to("#{pr.title.truncate(60)} ↗", pr.data["html_url"], rel: "noopener noreferrer", target: "_blank")
    end
    column :github_repo
    column :github_user do |pr|
      link_to("#{pr.github_user.login} ↗", pr.github_user.data["html_url"], rel: "noopener noreferrer", target: "_blank")
    end
    column :time_to_merge_in_days do |pr|
      pr.time_to_merge_in_days.try(:round, 2)
    end
    column :merged_at
  end
end
