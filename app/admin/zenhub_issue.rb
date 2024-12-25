ActiveAdmin.register ZenhubIssue do
  menu label: "Zenhub Issues"
  config.filters = true
  config.paginate = true
  actions :index, :show
  belongs_to :zenhub_workspace

  scope :all, default: true
  scope :has_estimate
  scope :no_estimate
  scope :closed
  scope :open
  scope :pull_requests
  scope :issues

  index download_links: false do
    column :is_pull_request
    column :title do |issue|
      link_to("#{issue.title.truncate(60)} ↗", issue.html_url, rel: "noopener noreferrer", target: "_blank")
    end
    column :github_repo
    column :author do |issue|
      link_to("#{issue.github_user.login} ↗", issue.github_user.data["html_url"], rel: "noopener noreferrer", target: "_blank")
    end
    column :assignees do |issue|
      issue.github_users.map { |user| link_to("#{user.login} ↗", user.data["html_url"], rel: "noopener noreferrer", target: "_blank") }.join(", ").html_safe
    end
    column :estimate
    column :closed_at
  end
end