class ReviewTree < ApplicationRecord
  acts_as_paranoid

  belongs_to :review
  belongs_to :tree

  def possible_trees
    if (tree.nil? || Tree.craft_trees.include?(tree))
      latest_review = self.review.admin_user.archived_reviews.first
      previous_craft_tree = if latest_review.present?
          latest_review.workspace.score_trees.map { |st| st.tree }.find { |t| Tree.craft_trees.include?(t) }
        end
      previous_craft_tree.present? ? [previous_craft_tree] : Tree.craft_trees
    else
      [tree]
    end
  end

  def can_change_tree
    tree.nil? || Tree.craft_trees.include?(tree)
  end
end
