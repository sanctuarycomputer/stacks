# Scan bookkeeping for the meeting sweep (Stacks::Meetings::Sweep), the sibling
# of ShipScan: one row per examined meeting. Keyed on a hash of the meeting's
# corpus-eligible documents, so a meeting is matched again only when what the
# sweep may read has changed. The model's one answer about the meeting (its
# confidence and its reason) lives here, once. human_locked scans are never
# touched by the sweep.
class MeetingScan < ApplicationRecord
  belongs_to :meeting

  enum outcome: { linked: 0, no_match: 1, out_of_scope: 2 }

  validates :outcome, :scanned_at, presence: true
end
