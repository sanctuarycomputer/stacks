class ReviewTree < ApplicationRecord
  belongs_to :review
  belongs_to :tree

  def possible_trees
    if (tree.nil? || Tree.craft_trees.include?(tree))
      Tree.craft_trees
    else
      [tree]
    end
  end

  def can_change_tree
    tree.nil? || Tree.craft_trees.include?(tree)
  end
end
