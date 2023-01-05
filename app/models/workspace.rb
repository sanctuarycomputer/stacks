class Workspace < ApplicationRecord
  acts_as_paranoid

  belongs_to :reviewable, polymorphic: true
  enum status: { draft: 0, complete: 1, archived: 2 }
  has_many :score_trees, -> {
    ScoreTree
      .where(workspace: self)
      .joins(:tree)
      .order_as_specified(trees: {
        name: ["Individual Contributor", "Strategist", "Designer", "Engineer", "Operations", "Communications", "Studio Impact"]
      })
  }, dependent: :destroy
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

  def sync!
    current_tree_ids = score_trees.map(&:tree_id)
    next_tree_ids = review.trees.map(&:id)
    remove = current_tree_ids - (current_tree_ids & next_tree_ids)
    add = next_tree_ids - (next_tree_ids & current_tree_ids)

    remove.each do |tree_id|
      score_trees.find { |st| st.tree_id == tree_id }.destroy!
    end
    add.each do |tree_id|
      prev_deleted = score_trees.with_deleted.find { |st| st.tree_id == tree_id }
      if prev_deleted
        # For some reason, recursive:true doesn't seem to work here. Not sure why
        # but not enough time to debug
        prev_deleted.recover(recursive: true, recovery_window: 100.years)
        prev_deleted.scores.with_deleted.each do |score|
          score.recover(recursive: true, recovery_window: 100.years)
        end
      else
        ScoreTree.create!({ tree_id: tree_id, workspace: self })
      end
    end
  end

  def build_score_trees
    self.score_trees = review.trees.map do |tree|
      ScoreTree.new({ tree: tree, workspace: self })
    end
  end
end
