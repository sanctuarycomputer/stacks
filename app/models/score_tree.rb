class ScoreTree < ApplicationRecord
  acts_as_paranoid

  belongs_to :tree
  belongs_to :workspace
  has_many :scores, -> { order "trait_id asc" }, dependent: :destroy
  before_create :build_scores
  accepts_nested_attributes_for :scores

  def display_name
    tree.name
  end

  def filled?
    scores.map { |s| s.band.present? && s.consistency.present? }.all?
  end

  def build_scores
    latest_review = self.workspace.review.admin_user.archived_reviews.first

    is_finalization_workspace = self.workspace.reviewable_type == "Finalization"
    latest_scores = []
    if latest_review.present? && !is_finalization_workspace
      latest_scores = latest_review.finalization.workspace.score_trees.map(&:scores).flatten
    end

    self.scores = tree.traits.map do |trait|
      prev_score = latest_scores.find { |s| s.trait == trait }
      Score.new({
        trait: trait,
        score_tree: self,
        band: prev_score.try(:band),
        consistency: prev_score.try(:consistency),
      })
    end
  end
end
