# Bookkeeping for the meeting matcher: one row per examined meeting. Keyed on
# a hash of the meeting's corpus-eligible documents, so a meeting is matched
# again only when what the matcher may read has changed. human_locked scans
# are never touched by the matcher.
class MeetingProjectScan < ApplicationRecord
  belongs_to :meeting
  enum outcome: { linked: 0, no_match: 1 }
  validates :outcome, :scanned_at, presence: true
end
