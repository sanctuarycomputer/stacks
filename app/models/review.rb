class Review < ApplicationRecord
  acts_as_paranoid

  belongs_to :admin_user
  has_many :peer_reviews, dependent: :delete_all
  has_one :finalization
  has_many :admin_users, through: :peer_reviews
  accepts_nested_attributes_for :peer_reviews, allow_destroy: true

  has_many :review_trees
  accepts_nested_attributes_for :review_trees, allow_destroy: true

  has_one :workspace, as: :reviewable
  before_create :build_workspace
  before_create :build_finalization

  def finalized_score_chart
    finalization.workspace.score_trees.reduce({}) do |acc, score_tree|
      score_tree.scores.each do |score|
        acc[score.trait.name] = acc[score.trait.name] || {
          band: score.band,
          consistency: score.consistency,
          sum: Score.bands[score.band] + Score.consistencies[score.consistency]
        }
      end
      acc
    end
  end

  def score_table
    all_reviews = [self, *self.peer_reviews]
    all_reviews.reduce({}) do |acc, review|
      review.workspace.score_trees.each do |score_tree|
        score_tree.scores.each do |score|
          acc[score.trait_id] = acc[score.trait_id] || {
            band: [],
            consistency: []
          }
          acc[score.trait_id][:band].push(score.band)
          acc[score.trait_id][:consistency].push(score.consistency)
        end
      end
      acc
    end
  end

  def reviewee
    admin_user
  end

  def trees
    review_trees.map(&:tree)
  end

  def archived?
    archived_at.present?
  end

  def finalized?
    finalization.workspace.complete?
  end

  def status
    if archived_at.present?
      "archived"
    elsif finalization.workspace.complete?
      "finalized"
    else
      workspace.status
    end
  end

  private

  def build_workspace
    self.workspace = Workspace.new
  end

  def build_finalization
    self.finalization = Finalization.new
  end
end
