class Meeting < ApplicationRecord
  has_many :documents, as: :source_record
  has_many :participants, class_name: 'MeetingParticipant', dependent: :destroy
  has_many :segments, class_name: 'MeetingTranscriptSegment', dependent: :destroy

  # Which project tracker(s) the meeting was about: a pure join table, written
  # by the nightly Stacks::Meetings::Sweep or by a person (link_project! and
  # unlink_project!). The sweep's bookkeeping, and the model's one answer about
  # the meeting, is the MeetingScan.
  has_and_belongs_to_many :project_trackers
  has_one :meeting_scan, dependent: :destroy

  enum meet_source: { meet_api: 0, drive: 1, gemini_notes: 2 }

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
  # the sweep's prompt and the Meeting Matches page never use it.
  def eligible_title(documents = eligible_documents.to_a)
    Meeting.notes_first(documents).map(&:title).find(&:present?)
  end

  # What the sweep was allowed to read, as one value: nil when nothing is.
  def eligible_content_hash
    Meeting.content_hash_for(eligible_documents.select(:id, :content_hash))
  end

  # The same value for documents already loaded. Callers pass eligible
  # documents only; the sweep hashes exactly the ones its prompt is built from.
  def self.content_hash_for(documents)
    parts = documents.map { |d| [d.id, d.content_hash] }.sort_by(&:first)
    return nil if parts.empty?
    Digest::SHA256.hexdigest(parts.map { |id, hash| "#{id}:#{hash}" }.join("|"))
  end

  # {meeting_id => sorted tracker ids} for the given meetings, in one query.
  # What the MCP document tools return: ids only, never the scan's reason.
  def self.project_tracker_ids_by_meeting(meeting_ids)
    meeting_ids = Array(meeting_ids).compact.uniq
    return {} if meeting_ids.empty?
    # Deploys can land before migrations: without the join table, no matches
    # (not a crash). Asked each time, so the answer is never a stale "missing".
    return {} unless ActiveRecord::Base.connection.table_exists?("meetings_project_trackers")
    where(id: meeting_ids).joins(:project_trackers).pluck("meetings.id", "project_trackers.id")
      .group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }
  end

  # A person says this meeting was about the tracker. Any change a person
  # makes locks the meeting's scan, so the sweep leaves it alone from then on
  # (the sweep itself writes the join directly and never calls these).
  # Only a meeting the corpus can read may be linked: this must not become a
  # way to file a private meeting.
  def link_project!(tracker)
    if eligible_documents.none?
      errors.add(:base, "This meeting has no document in the Stacks corpus")
      raise ActiveRecord::RecordInvalid, self
    end
    transaction do
      project_trackers << tracker unless project_trackers.exists?(tracker.id)
      lock_scan_for_person!
    end
  rescue ActiveRecord::RecordNotUnique
    # A double submit, or the sweep linking the same tracker at the same
    # moment: the link exists, which is what was asked for.
    reload
    transaction { lock_scan_for_person! }
  end

  # A person says this meeting was not about the tracker.
  def unlink_project!(tracker)
    transaction do
      project_trackers.delete(tracker)
      lock_scan_for_person!
    end
  end

  # The ETL folds a standalone notes meeting into the meeting its transcript
  # belongs to, then destroys it. Its matches come along: trackers the
  # survivor lacks are moved, and the scan is moved when the survivor has
  # none. When both have a scan the survivor's stays, locked if either was,
  # so a person's correction survives.
  #
  # Whichever scan the survivor ends up with loses its reason, confidence and
  # hash: they were written about a different set of documents, some of which
  # may since have been excluded. With no hash an unlocked scan is matched
  # again, and no "Why" is shown until it has been.
  def absorb_project_matches_from!(other)
    transaction do
      (other.project_trackers.to_a - project_trackers.to_a).each { |tracker| project_trackers << tracker }
      other.project_trackers.clear
      theirs = MeetingScan.find_by(meeting_id: other.id)
      scan = MeetingScan.find_by(meeting_id: id)
      if scan
        scan.human_locked = true if theirs&.human_locked?
      elsif theirs
        theirs.meeting_id = id
        scan = theirs
        # So destroying the other meeting does not take the moved scan with it.
        other.association(:meeting_scan).reset
      end
      next if scan.nil?
      # The outcome says what the survivor has now, not what either had before.
      scan.assign_attributes(scanned_hash: nil, rationale: nil, confidence: nil,
                             outcome: project_trackers.exists? ? :linked : :no_match)
      scan.save!
      association(:meeting_scan).reset
    end
  end

  private

  def lock_scan_for_person!
    scan = MeetingScan.find_or_initialize_by(meeting_id: id)
    # The hash is set only for a new scan: on an existing one it says what the
    # stored reason was written from, and a person's edit does not change that.
    scan.scanned_hash = eligible_content_hash if scan.new_record?
    scan.update!(outcome: project_trackers.exists? ? :linked : :no_match, human_locked: true, scanned_at: Time.zone.now)
    association(:meeting_scan).reset
  end
end
