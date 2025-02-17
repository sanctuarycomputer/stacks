class GithubRepo < ApplicationRecord
  self.primary_key = "github_id"
  has_many :github_pull_requests, class_name: "GithubPullRequest", foreign_key: "github_repo_id", dependent: :destroy
  has_many :zenhub_workspace_github_repository_connections, class_name: "ZenhubWorkspaceGithubRepositoryConnection", foreign_key: "github_repo_id", dependent: :destroy
  has_many :zenhub_workspaces, through: :zenhub_workspace_github_repository_connections, dependent: :destroy
  has_many :zenhub_issues, class_name: "ZenhubIssue", foreign_key: "github_repo_id", dependent: :destroy
  has_many :github_issues, class_name: "GithubIssue", foreign_key: "github_repo_id", dependent: :destroy

  def average_time_to_merge_in_days
    av = github_pull_requests.merged.average(:time_to_merge)
    return nil unless av.present?
    av / 86400.to_f
  end
end

