class GithubIssue < ApplicationRecord
  self.primary_key = "github_id"
  belongs_to :github_repo
  belongs_to :github_user
  has_one :zenhub_issue

  def self.without_zenhub_issue
    # First, let's see all issues that are in repos connected to Zenhub
    connected_issues = GithubIssue
      .joins(github_repo: :zenhub_workspace_github_repository_connections)
      .distinct

    # Finally, find the difference
    connected_issues
      .where.not(github_id: ZenhubIssue.pluck(:github_issue_id))
      .where.not(github_node_id: ZenhubIssue.pluck(:github_issue_node_id))
  end
end

