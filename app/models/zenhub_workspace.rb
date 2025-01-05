class ZenhubWorkspace < ApplicationRecord
  self.primary_key = "zenhub_id"
  has_many :zenhub_workspace_github_repository_connections, class_name: "ZenhubWorkspaceGithubRepositoryConnection", foreign_key: "zenhub_workspace_id"
  has_many :github_repos, through: :zenhub_workspace_github_repository_connections

  has_many :zenhub_workspace_issue_connections, class_name: "ZenhubWorkspaceIssueConnection", foreign_key: "zenhub_workspace_id"
  has_many :zenhub_issues, through: :zenhub_workspace_issue_connections

  def total_story_points
    zenhub_issues.sum(:estimate)
  end

  def html_url
    "https://app.zenhub.com/workspaces/#{zenhub_id}/board"
  end
end
