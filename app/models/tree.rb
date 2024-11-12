class Tree < ApplicationRecord
  has_many :traits

  def self.craft_trees
    where(name: ["Strategist", "Designer", "Engineer", "Operations", "Communications", "Project Delivery"])
  end

  def display_name
    name
  end

  def self.seed_communications
    tree = Tree.create!(name: "Communications")
    Trait.create!(name: "Owned Channels", tree: tree)
    Trait.create!(name: "Paid Media", tree: tree)
    Trait.create!(name: "Community & Outreach", tree: tree)
    Trait.create!(name: "Strategy, Analysis & Reporting", tree: tree)
    Trait.create!(name: "Asset & Content Production", tree: tree)
  end

  def self.seed_project_delivery
    tree = Tree.create!(name: "Project Delivery")
    Trait.create!(name: "Work Management", tree: tree)
    Trait.create!(name: "Project Budget & Hours Management", tree: tree)
    Trait.create!(name: "Project Scope Management", tree: tree)
    Trait.create!(name: "Project Management", tree: tree)
    Trait.create!(name: "Client Relationship", tree: tree)
  end
end
