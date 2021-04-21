class PeerReview < ApplicationRecord
  acts_as_paranoid

  belongs_to :admin_user
  belongs_to :review

  has_one :workspace, as: :reviewable, dependent: :destroy
  before_create :build_workspace

  validates_uniqueness_of :admin_user, scope: :review_id

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
