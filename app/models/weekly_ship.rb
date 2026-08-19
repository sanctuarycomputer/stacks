# One (ship email × project tracker) link. Created by the nightly
# Stacks::WeeklyShips::Sweep (matched_by: llm, via_sweep set) or by humans in
# ActiveAdmin (matched_by defaults to human). Any human write locks the
# document's ShipScan so the sweep never overrides human judgment.
class WeeklyShip < ApplicationRecord
  belongs_to :document
  belongs_to :project_tracker

  enum matched_by: { llm: 0, human: 1 }

  validates :sent_at, presence: true
  validates :project_tracker_id, uniqueness: { scope: :document_id }

  # Set by the sweep so pipeline writes skip the human-lock callbacks.
  attr_accessor :via_sweep

  # {tracker_id => newest WeeklyShip} for the given ids, one query.
  def self.latest_by_tracker(tracker_ids)
    where(project_tracker_id: tracker_ids)
      .order(:project_tracker_id, sent_at: :desc)
      .group_by(&:project_tracker_id)
      .transform_values(&:first)
  end

  before_validation { self.matched_by ||= :human unless via_sweep }

  after_save    :human_lock_scan!, unless: :via_sweep
  after_destroy :human_lock_scan_after_destroy!, unless: :via_sweep

  private

  def human_lock_scan!
    upsert_scan!(outcome: :linked)
  end

  def human_lock_scan_after_destroy!
    outcome = document.weekly_ships.where.not(id: id).exists? ? :linked : :no_match
    upsert_scan!(outcome: outcome)
  end

  def upsert_scan!(outcome:)
    scan = ShipScan.find_or_initialize_by(document: document)
    scan.update!(outcome: outcome, human_locked: true,
                 scanned_at: Time.zone.now,
                 scanned_content_hash: document.content_hash)
  end
end
