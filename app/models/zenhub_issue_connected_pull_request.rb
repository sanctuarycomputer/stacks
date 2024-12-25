class ZenhubIssueConnectedPullRequest < ApplicationRecord
  self.primary_key = "zenhub_issue_id"
  belongs_to :zenhub_pull_request_issue, class_name: "ZenhubIssue", foreign_key: "zenhub_pull_request_issue_id"
end