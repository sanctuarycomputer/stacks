class ZenhubWorkspaceIssueConnection < ApplicationRecord
  belongs_to :zenhub_workspace
  belongs_to :zenhub_issue
end
