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
    scores.map{|s| s.band.present? && s.consistency.present?}.all?
  end

  def build_scores
    self.scores = tree.traits.map do |trait|
      Score.new({ trait: trait, score_tree: self })
    end
  end
end
