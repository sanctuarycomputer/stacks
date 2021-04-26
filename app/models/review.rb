class Review < ApplicationRecord
  acts_as_paranoid

  belongs_to :admin_user

  has_many :peer_reviews, dependent: :destroy
  has_one :finalization, dependent: :destroy
  has_many :review_trees, dependent: :destroy
  has_one :workspace, as: :reviewable, dependent: :destroy
  has_many :admin_users, through: :peer_reviews

  accepts_nested_attributes_for :peer_reviews, allow_destroy: true
  accepts_nested_attributes_for :review_trees, allow_destroy: true

  before_create :build_workspace
  before_create :build_finalization
  after_update :ensure_workspaces_in_sync

  validate :must_be_same_craft

  def must_be_same_craft
    previous_review_tree =
      admin_user.archived_reviews.first.try(:craft_review_tree)
    unless previous_review_tree.nil?
      if (previous_review_tree.tree != craft_review_tree.tree)
        errors.add(:base, "review tree error")
        craft_review_tree.errors.add(:tree, "must match previous reviews")
      end
    end
  end

  def craft_review_tree
    review_trees.find{|rt| Tree.craft_trees.include?(rt.tree)}
  end

  def finalized_score_chart
    finalization.workspace.score_trees.reduce({}) do |acc, score_tree|
      score_tree.scores.each do |score|
        acc[score.trait.name] = acc[score.trait.name] || {
          band: score.band,
          consistency: score.consistency,
          sum: score.score_to_points
        }
      end
      acc
    end
  end

  def total_points
    finalization.workspace.score_trees.reduce(0) do |acc, score_tree|
      points = score_tree.scores.reduce(0) do |acc, score|
        acc + score.score_to_points
      end
      acc + points
    end
  end

  LEVELS = {
    junior_1: {
      name: "J1",
      min_points: 100,
      salary: 60000
    },
    junior_2: {
      name: "J2",
      min_points: 155,
      salary: 63500
    },
    junior_3: {
      name: "J3",
      min_points: 210,
      salary: 67000
    },
    mid_level_1: {
      name: "ML1",
      min_points: 265,
      salary: 70000
    },
    mid_level_2: {
      name: "ML2",
      min_points: 320,
      salary: 73500
    },
    mid_level_3: {
      name: "ML3",
      min_points: 375,
      salary: 77000
    },
    experienced_mid_level_1: {
      name: "EML1",
      min_points: 430,
      salary: 80000
    },
    experienced_mid_level_2: {
      name: "EML2",
      min_points: 485,
      salary: 85000
    },
    experienced_mid_level_3: {
      name: "EML3",
      min_points: 540,
      salary: 90000
    },
    senior_1: {
      name: "S1",
      min_points: 595,
      salary: 95000
    },
    senior_2: {
      name: "S2",
      min_points: 650,
      salary: 100000
    },
    senior_3: {
      name: "S3",
      min_points: 705,
      salary: 105000
    },
    senior_4: {
      name: "S4",
      min_points: 760,
      salary: 110000
    },
    lead_1: {
      name: "L1",
      min_points: 815,
      salary: 115000
    },
    lead_2: {
      name: "L2",
      min_points: 870,
      salary: 120000
    },
  }

  def level
    LEVELS.keys.reduce(nil) do |acc, l|
      if acc.nil?
        LEVELS[:junior_1]
      else
        if LEVELS[l][:min_points] <= total_points
          LEVELS[l]
        else
          acc
        end
      end
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
      if workspace.status == "complete"
        all_peers_complete = peer_reviews.map(&:status).all?{|s| s == "complete"}
        if all_peers_complete
          "ready"
        else
          "waiting"
        end
      else
        workspace.status
      end
    end
  end

  private

  def build_workspace
    self.workspace = Workspace.new
  end

  def build_finalization
    self.finalization = Finalization.new
  end

  def ensure_workspaces_in_sync
    workspace.sync!
    peer_reviews.each{|pr| pr.workspace.sync!}
    finalization.workspace.sync!
  end
end
