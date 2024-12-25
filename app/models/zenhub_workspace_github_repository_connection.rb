class ZenhubWorkspaceGithubRepositoryConnection < ApplicationRecord
  self.primary_key = "zenhub_id"
  belongs_to :zenhub_workspace, class_name: "ZenhubWorkspace", foreign_key: "zenhub_workspace_id"
  belongs_to :github_repo, class_name: "GithubRepo", foreign_key: "github_repo_id"
end