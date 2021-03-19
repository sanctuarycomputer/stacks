class PeerReview < ApplicationRecord
  acts_as_paranoid

  belongs_to :admin_user
  belongs_to :review

  has_one :workspace, as: :reviewable
  before_create :build_workspace

  def reviewee
    review.admin_user
  end

  def status
    if review.archived_at.present?
      "archived"
    elsif review.finalization.workspace.complete?
      "finalized"
    else
      workspace.status
    end
  end

  private

  def build_workspace
    self.workspace = Workspace.new
  end
end
