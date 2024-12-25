ActiveAdmin.register GithubUser do
  menu label: "Github Users", parent: "Github & Zenhub"
  config.filters = false
  config.paginate = false
  actions :index, :show

  index download_links: false do
    column :name do |user|
      link_to(user.name, user.data["html_url"], rel: "noopener noreferrer", target: "_blank")
    end

    column :total_prs do |user|
      user.github_pull_requests.count
    end

    column :total_story_points

    column :average_time_to_merge_in_days do |user|
      user.average_time_to_merge_in_days.try(:round, 2)
    end
  end
end
