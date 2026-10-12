# One project tracker a meeting was about. Made by the nightly matcher
# (Stacks::Meetings::ProjectMatcher) or by a person; any change a person
# makes locks the meeting's scan, so the matcher leaves it alone from then on.
class MeetingProjectTracker < ApplicationRecord
  belongs_to :meeting
  belongs_to :project_tracker

  enum matched_by: { llm: 0, human: 1 }

  # Set by the matcher on its own writes; anything else is a person.
  attr_accessor :via_matcher

  validates :project_tracker_id, uniqueness: { scope: :meeting_id }
  # A person may only link a meeting the corpus can read: the form that makes
  # these links must not become a way to see or file a private meeting.
  validate :meeting_must_be_readable, unless: :via_matcher

  # {meeting_id => sorted tracker ids} for the given meetings, in one query.
  # What the MCP document tools return: ids only, never the rationale.
  def self.tracker_ids_by_meeting(meeting_ids)
    meeting_ids = Array(meeting_ids).compact.uniq
    # Deploys land before migrations on Heroku: without the table, no matches (not a crash).
    return {} if meeting_ids.empty? || !table_exists?
    where(meeting_id: meeting_ids).pluck(:meeting_id, :project_tracker_id)
      .group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }
  end

  before_validation { self.matched_by = :human unless via_matcher || persisted? }

  after_save    :human_lock_scan!, unless: :via_matcher
  after_destroy :human_lock_scan!, unless: :via_matcher

  private

  def meeting_must_be_readable
    return if meeting.nil?
    errors.add(:meeting, "has no document in the Stacks corpus") if meeting.eligible_documents.none?
  end

  def human_lock_scan!
    return if meeting.nil?
    remaining = MeetingProjectTracker.where(meeting_id: meeting_id)
    remaining = remaining.where.not(id: id) if destroyed?
    scan = MeetingProjectScan.find_or_initialize_by(meeting: meeting)
    # The hash is set only for a new scan: on an existing one it says what the
    # stored rationale was written from, and a person's edit does not change that.
    scan.scanned_hash = meeting.eligible_content_hash if scan.new_record?
    scan.update!(outcome: remaining.exists? ? :linked : :no_match, human_locked: true, scanned_at: Time.zone.now)
  end
end
