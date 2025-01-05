class ZenhubIssue < ApplicationRecord
  self.primary_key = "zenhub_id"
  has_many :zenhub_workspace_issue_connections, class_name: "ZenhubWorkspaceIssueConnection", foreign_key: "zenhub_issue_id"
  has_many :zenhub_workspaces, through: :zenhub_workspace_issue_connections
  belongs_to :github_repo, class_name: "GithubRepo", foreign_key: "github_repo_id"
  belongs_to :github_user, class_name: "GithubUser", foreign_key: "github_user_id"
  belongs_to :github_issue, ->(issue) { where("github_id = ? OR github_node_id = ?", issue.github_issue_id, issue.github_issue_node_id) }, class_name: "GithubIssue"
  # has_many :zenhub_issue_connected_pull_requests, class_name: "ZenhubIssueConnectedPullRequest", foreign_key: "zenhub_issue_id"
  # has_many :zenhub_pull_request_issues, through: :zenhub_issue_connected_pull_requests, source: :zenhub_pull_request_issue
  has_many :zenhub_issue_assignees, class_name: "ZenhubIssueAssignee", foreign_key: "zenhub_issue_id"
  has_many :github_users, through: :zenhub_issue_assignees, source: :github_user

  scope :pull_requests, -> { where(is_pull_request: true) }
  scope :issues, -> { where(is_pull_request: false) }
  scope :has_estimate, -> { where.not(estimate: nil) }
  scope :no_estimate, -> { where(estimate: nil) }
  scope :closed, -> { where.not(closed_at: nil) }
  scope :open, -> { where(closed_at: nil) }

  enum issue_type: {
    "GithubIssue": 0,
    "ZenhubIssue": 1
  }
  enum issue_state: {
    "OPEN": 0,
    "CLOSED": 1
  }

  def html_url
    "https://app.zenhub.com/workspaces/#{zenhub_workspaces.first.zenhub_id}/issues/gh/sanctuarycomputer/#{github_repo.name}/#{number}"
  end
end
