class ZenhubIssueAssignee < ApplicationRecord
  self.primary_key = "zenhub_issue_id"
  belongs_to :zenhub_issue, class_name: "ZenhubIssue", foreign_key: "zenhub_issue_id"
  belongs_to :github_user, class_name: "GithubUser", foreign_key: "github_user_id"
end
