class GithubUser < ApplicationRecord
  self.primary_key = "github_id"
  has_many :github_pull_requests, class_name: "GithubPullRequest", foreign_key: "github_user_id"
  has_many :zenhub_issue_assignees, class_name: "ZenhubIssueAssignee", foreign_key: "github_user_id"
  has_many :zenhub_issues, through: :zenhub_issue_assignees, source: :zenhub_issue

  def name
    login
  end

  def average_time_to_merge_in_days
    av = github_pull_requests.merged.average(:time_to_merge)
    return nil unless av.present?
    av / 86400.to_f
  end
end
