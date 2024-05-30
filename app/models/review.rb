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
  validate :cannot_be_archived_unless_finalization_is_complete

  def cannot_be_archived_unless_finalization_is_complete
    if changes.dig("archived_at", 0).nil? && changes.dig("archived_at", 1).present?
      unless finalization.workspace.status == "complete"
        errors.add(:status, "Please fill out all scores and Mark as Finalized before archiving.")
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

  def level
    levels = Stacks::SkillLevelFinder.find_all!(Date.today)
    actual_points = total_points

    descending_levels = levels.sort do |a, b|
      b[:min_points] <=> a[:min_points]
    end

    descending_levels.each do |level|
      if level[:min_points] <= actual_points
        return level
      end
    end

    descending_levels.last
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

    if archived?
      sync_salary_windows!
    end
  end

  def sync_salary_windows!
    syncer = Stacks::AdminUserSalaryWindowSyncer.new(self.admin_user)
    syncer.sync!
  end
end
