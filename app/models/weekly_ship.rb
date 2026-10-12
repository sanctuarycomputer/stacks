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
  validate :document_must_be_ships_group

  # Ships whose document is still inside the ETL corpus wall. A ships@ document
  # can be manually excluded after it was linked (the sweep never removes
  # links), and the MCP read tools must not surface its title or permalink,
  # matching what get_document already refuses to return.
  scope :corpus_eligible, -> { joins(:document).merge(Document.corpus_eligible) }

  # Set by the sweep so pipeline writes skip the human-lock callbacks.
  attr_accessor :via_sweep

  # {tracker_id => newest WeeklyShip} for the given ids, one query.
  def self.latest_by_tracker(tracker_ids)
    where(project_tracker_id: tracker_ids)
      .order(:project_tracker_id, sent_at: :desc)
      .group_by(&:project_tracker_id)
      .transform_values(&:first)
  end

  # The grade Stacks::WeeklyShips::Grader stored for this email, or nil.
  def grade
    # Deploys land before migrations on Heroku: without the column, no grade (not a crash).
    return nil unless has_attribute?(:metadata)
    scoring = (metadata || {})["scoring"]
    scoring.is_a?(Hash) && scoring["stars"].is_a?(Integer) ? scoring : nil
  end

  # The grade as the MCP tools return it: the coaching, not the rubric internals.
  def grade_json
    g = grade
    return nil if g.nil?
    { stars: g["stars"], summary: g["summary"], suggestions: g["suggestions"],
      rubric_version: g["rubric_version"], graded_at: g["graded_at"] }
  end

  def self.stars_label(stars)
    n = stars.to_i.clamp(0, 5)
    ("★" * n) + ("☆" * (5 - n))
  end

  # The pill colour for a tracker's last ship: the worse of how stale it is and
  # how it graded, so a fresh two-star ship and a five-star ship from six weeks
  # ago both stand out. An ungraded ship is coloured by staleness alone.
  # ("exceptional", not "complete": .complete is re-declared purple later in the
  # stylesheet cascade; .exceptional is the stable green.)
  PILL_CLASSES = %w[exceptional at_risk error].freeze
  PILL_COLOURS = [nil, "Orange", "Red"].freeze
  STALENESS_SEVERITY = { fresh: 0, stale: 1, overdue: 2 }.freeze
  # The day counts ProjectTracker.ship_staleness cuts at, by severity.
  STALENESS_DAYS = { 1 => 10, 2 => 30 }.freeze

  def self.pill_class(staleness:, stars: nil)
    "pill #{PILL_CLASSES[pill_severities(staleness, stars).max]}"
  end

  # Why the pill is orange or red, for its hover title; nil when it is green.
  # Names whichever of staleness and grade set the colour, or both when tied.
  def self.pill_reason(staleness:, stars: nil)
    stale, graded = pill_severities(staleness, stars)
    worst = [stale, graded].max
    return nil if worst.zero?
    behind = "the last ship is more than #{STALENESS_DAYS[worst]} days behind the project's last scheduled hours"
    reason =
      if stale == graded then "#{behind}, and it scored #{stars} of 5"
      elsif stale == worst then behind
      else "the last ship scored #{stars} of 5"
      end
    "#{PILL_COLOURS[worst]}: #{reason}."
  end

  # [staleness, grade] as 0 green, 1 orange, 2 red. Stars that are not a whole
  # number count as ungraded, like a ship with no grade.
  def self.pill_severities(staleness, stars)
    grade_severity =
      if !stars.is_a?(Integer) || stars >= 4 then 0
      elsif stars == 3 then 1
      else 2
      end
    [STALENESS_SEVERITY.fetch(staleness, 0), grade_severity]
  end
  private_class_method :pill_severities

  # The ship before the email these rows link: the newest earlier ship (a
  # different email, still inside the corpus wall) on any of its trackers. One
  # definition, so the coaching page shows the ship the grader compared against.
  def self.previous_to(ships)
    ships = Array(ships)
    return nil if ships.empty?
    corpus_eligible.includes(:document)
      .where(project_tracker_id: ships.map(&:project_tracker_id))
      .where.not(document_id: ships.first.document_id)
      .where("weekly_ships.sent_at < ?", ships.map(&:sent_at).min)
      .order(sent_at: :desc, id: :desc).first
  end

  def previous_ship
    WeeklyShip.previous_to(WeeklyShip.where(document_id: document_id).to_a)
  end

  # The email's subject, or a stand-in when it has none.
  def display_title
    document.title.presence || "Weekly ship, #{sent_at.strftime("%B %-d, %Y")}"
  end

  # Who sent the ship, or nil when the email recorded neither a name nor an address.
  def sender
    sent_by_name.presence || sent_by_email.presence
  end

  def sender_label
    sender || "Unknown sender"
  end

  before_validation { self.matched_by ||= :human unless via_sweep }

  after_save    :human_lock_scan!, unless: :via_sweep
  after_save    :reevaluate_old_document_scan!, unless: :via_sweep
  after_destroy :human_lock_scan_after_destroy!, unless: -> { via_sweep || destroyed_by_association }

  private

  def document_must_be_ships_group
    return if document.nil?
    unless document.google_groups? &&
           document.raw_metadata&.dig("group_email") == Document::SHIPS_GROUP_EMAIL
      errors.add(:document, "must be a ships@ Google Groups document")
    end
  end

  def human_lock_scan!
    upsert_scan!(outcome: :linked)
  end

  # When a human updates a ship to a different document, re-evaluate the OLD
  # document's scan. If it now has no remaining weekly_ships, mark it no_match
  # (keep human_locked: true so the sweep won't override the judgment).
  def reevaluate_old_document_scan!
    return unless saved_change_to_document_id?
    old_doc_id = saved_change_to_document_id.first
    return if old_doc_id.nil?
    old_doc = Document.find_by(id: old_doc_id)
    return if old_doc.nil?
    return if old_doc.weekly_ships.where.not(id: id).exists?
    scan = ShipScan.find_by(document: old_doc)
    return if scan.nil?
    scan.update!(outcome: :no_match, human_locked: true, scanned_at: Time.zone.now,
                 scanned_content_hash: old_doc.content_hash)
  end

  def human_lock_scan_after_destroy!
    return if document.nil?
    outcome = document.weekly_ships.where.not(id: id).exists? ? :linked : :no_match
    upsert_scan!(outcome: outcome)
  end

  def upsert_scan!(outcome:)
    return if document.nil?
    scan = ShipScan.find_or_initialize_by(document: document)
    scan.update!(outcome: outcome, human_locked: true,
                 scanned_at: Time.zone.now,
                 scanned_content_hash: document.content_hash)
  end
end
