class ZenhubWorkspace < ApplicationRecord
  self.primary_key = "zenhub_id"
  has_many :zenhub_workspace_github_repository_connections, class_name: "ZenhubWorkspaceGithubRepositoryConnection", foreign_key: "zenhub_workspace_id"
  has_many :github_repos, through: :zenhub_workspace_github_repository_connections

  has_many :zenhub_workspace_issue_connections, class_name: "ZenhubWorkspaceIssueConnection", foreign_key: "zenhub_workspace_id"
  has_many :zenhub_issues, through: :zenhub_workspace_issue_connections

  has_many :project_tracker_zenhub_workspaces, dependent: :delete_all
  has_many :project_trackers, through: :project_tracker_zenhub_workspaces

  def total_story_points
    zenhub_issues.sum(:estimate)
  end

  def html_url
    "https://app.zenhub.com/workspaces/#{zenhub_id}/board"
  end

  def average_time_to_merge_pr
    prs = GithubPullRequest
      .where(github_repo: github_repos.map(&:id))
      .merged

    ttm = prs.average(:time_to_merge)
    (ttm.present? ? (ttm / 86400.to_f) : nil).try(:round, 2)
  end

  def average_time_to_merge_pr_in_days_during_range(start_range, end_range)
    prs = GithubPullRequest
      .where(merged_at: start_range..end_range)
      .where(github_repo: github_repos.map(&:id))
      .merged

    ttm = prs.average(:time_to_merge)
    (ttm.present? ? (ttm / 86400.to_f) : nil).try(:round, 2)
  end
end
