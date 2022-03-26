class Finalization < ApplicationRecord
  acts_as_paranoid

  belongs_to :review
  has_one :workspace, as: :reviewable, dependent: :destroy
  accepts_nested_attributes_for :workspace

  before_create :build_workspace

  scope :finalized, -> {
    Finalization.all
  }

  def compliant?
    if ["archived", "finalized"].include?(review.status)
      review.admin_users.map{|u| u.skill_tree_level_on_date(created_at)}.any? do |skill_level|
        review.level[:min_points] <= skill_level[:min_points]
      end
    end
  end

  private

  def build_workspace
    self.workspace = Workspace.new
  end
end
