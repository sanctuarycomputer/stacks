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

  # Notes before the transcript (they are the summary), then oldest first.
  def self.notes_first(documents)
    documents.sort_by { |d| [d.gemini_notes? ? 0 : 1, d.id] }
  end

  # A title the corpus may read, or nil. `title` itself is overwritten by
  # whichever document was ingested last, which can be an excluded one, so
  # the matcher's prompt and the Meeting Matches page never use it.
  def eligible_title(documents = eligible_documents.to_a)
    Meeting.notes_first(documents).map(&:title).find(&:present?)
  end

  # What the matcher was allowed to read, as one value: nil when nothing is.
  def eligible_content_hash
    Meeting.content_hash_for(eligible_documents.select(:id, :content_hash))
  end

  # The same value for documents already loaded. Callers pass eligible
  # documents only; the matcher hashes exactly the ones its prompt is built from.
  def self.content_hash_for(documents)
    parts = documents.map { |d| [d.id, d.content_hash] }.sort_by(&:first)
    return nil if parts.empty?
    Digest::SHA256.hexdigest(parts.map { |id, hash| "#{id}:#{hash}" }.join("|"))
  end

  # The ETL folds a standalone notes meeting into the meeting its transcript
  # belongs to, then destroys it. Its matches come along: links the survivor
  # lacks are moved (no callbacks, so nothing is locked by the move), and the
  # scan is moved when the survivor has none. When both have a scan the
  # survivor's stays, locked if either was, so a person's correction survives.
  #
  # A moved link loses its rationale and confidence: they were written about
  # a different set of documents, some of which may since have been excluded.
  # A scan the survivor already had loses its hash for the same reason: no
  # "Why" is shown until the matcher has read the merged meeting (an unlocked
  # scan is matched again; a locked one just shows no reason).
  def absorb_project_matches_from!(other)
    return unless MeetingProjectTracker.table_exists?
    already = MeetingProjectTracker.where(meeting_id: id).pluck(:project_tracker_id)
    MeetingProjectTracker.where(meeting_id: other.id).where.not(project_tracker_id: already)
                         .update_all(meeting_id: id, rationale: nil, confidence: nil)
    theirs = MeetingProjectScan.find_by(meeting_id: other.id)
    scan = MeetingProjectScan.find_by(meeting_id: id)
    if scan
      scan.update_columns(scanned_hash: nil, human_locked: scan.human_locked? || theirs&.human_locked? || false)
    elsif theirs
      theirs.update_columns(meeting_id: id)
      scan = theirs
    end
    return if scan.nil?
    # The outcome says what the survivor has now, not what either had before.
    linked = MeetingProjectTracker.where(meeting_id: id).exists?
    scan.update_columns(outcome: MeetingProjectScan.outcomes[linked ? :linked : :no_match])
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
