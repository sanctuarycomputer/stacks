class Workspace < ApplicationRecord
  belongs_to :reviewable, polymorphic: true
  enum status: { draft: 0, complete: 1, archived: 2 }
  has_many :score_trees, -> { order "tree_id asc" }
  accepts_nested_attributes_for :score_trees
  validate :status_can_not_transition_to_complete_unless_scores_inputted

  def status_can_not_transition_to_complete_unless_scores_inputted
    if changes["status"] == ["draft", "complete"]
      unless score_trees.map(&:filled?).all?
        errors.add(:status, "Please fill out all scores before marking as this workspace as complete.")
      end
    end
  end

  before_create :build_score_trees

  def review
    if reviewable_type == "PeerReview"
      reviewable.review
    elsif reviewable_type == "Finalization"
      reviewable.review
    else
      reviewable
    end
  end

  def display_name
    "Finalized:"
  end

  def build_score_trees
    self.score_trees = review.trees.map do |tree|
      ScoreTree.new({ tree: tree, workspace: self })
    end
  end
end
