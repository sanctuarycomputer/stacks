class GithubPullRequest < ApplicationRecord
  self.primary_key = "github_id"
  belongs_to :github_repo, class_name: "GithubRepo", foreign_key: "github_repo_id"
  belongs_to :github_user, class_name: "GithubUser", foreign_key: "github_user_id"

  scope :merged, -> { where.not(merged_at: nil) }

  def time_to_merge_in_days
    return nil unless time_to_merge.present?
    time_to_merge / 86400.to_f
  end
end
