class Tree < ApplicationRecord
  has_many :traits

  def self.craft_trees
    where(name: ["Strategist", "Designer", "Engineer", "Operations", "Communications", "Project Delivery", "Business Development"])
  end

  def display_name
    name
  end
end
