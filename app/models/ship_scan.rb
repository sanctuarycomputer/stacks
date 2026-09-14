# Scan bookkeeping for the weekly-ship sweep — one row per examined ships@
# document. Keyed on content_hash so reply-clobbered threads (the ETL rebuilds
# a thread's document when replies arrive) get re-scanned. human_locked scans
# are never touched by the sweep.
class ShipScan < ApplicationRecord
  belongs_to :document

  enum outcome: { linked: 0, no_match: 1, not_a_ship: 2, out_of_scope: 3 }

  validates :outcome, :scanned_at, presence: true
end
