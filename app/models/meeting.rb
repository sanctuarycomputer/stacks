class Meeting < ApplicationRecord
  has_many :documents, as: :source_record
  has_many :participants, class_name: 'MeetingParticipant', dependent: :destroy
  has_many :segments, class_name: 'MeetingTranscriptSegment', dependent: :destroy

  # Which project tracker(s) the meeting was about (Stacks::Meetings::ProjectMatcher).
  # No `dependent:` here: see remove_project_matches.
  has_many :meeting_project_trackers
  has_many :project_trackers, through: :meeting_project_trackers
  has_one :meeting_project_scan

  enum meet_source: { meet_api: 0, drive: 1, gemini_notes: 2 }

  before_destroy :remove_project_matches

  # The documents of this meeting the corpus may read (transcript and/or notes).
  def eligible_documents
    documents.corpus_eligible
  end

  # What the matcher was allowed to read, as one value: nil when nothing is.
  def eligible_content_hash
    parts = eligible_documents.pluck(:id, :content_hash).sort_by(&:first)
    return nil if parts.empty?
    Digest::SHA256.hexdigest(parts.map { |id, hash| "#{id}:#{hash}" }.join("|"))
  end

  # The ETL folds a standalone notes meeting into the meeting its transcript
  # belongs to, then destroys it. Its matches come along: links the survivor
  # lacks are moved (no callbacks, so nothing is locked by the move), and the
  # scan is moved when the survivor has none. When both have a scan the
  # survivor's stays, locked if either was, so a person's correction survives.
  def absorb_project_matches_from!(other)
    return unless MeetingProjectTracker.table_exists?
    already = MeetingProjectTracker.where(meeting_id: id).pluck(:project_tracker_id)
    MeetingProjectTracker.where(meeting_id: other.id).where.not(project_tracker_id: already)
                         .update_all(meeting_id: id)
    theirs = MeetingProjectScan.find_by(meeting_id: other.id)
    return if theirs.nil?
    mine = MeetingProjectScan.find_by(meeting_id: id)
    if mine.nil?
      theirs.update_columns(meeting_id: id)
    elsif theirs.human_locked? && !mine.human_locked?
      mine.update_columns(human_locked: true)
    end
  end

  private

  # Deploys land before migrations: `dependent: :destroy` would query a table
  # that is not there yet and fail every Meeting destroy the ETL makes.
  def remove_project_matches
    return unless MeetingProjectTracker.table_exists?
    MeetingProjectTracker.where(meeting_id: id).delete_all
    MeetingProjectScan.where(meeting_id: id).delete_all
  end
end
