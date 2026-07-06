class BackfillAllLedgers < ActiveRecord::Migration[6.1]
  # Pre-create a Ledger for every (Enterprise, Contributor) pair so a
  # contributor can submit a reimbursement / receive a pay stub against
  # ANY enterprise without first needing one to be lazily created.
  # `Ledger.ensure_all!` is idempotent and bulk-inserts only the missing
  # rows, so this is safe to run against a partially-populated prod DB.
  def up
    inserted = Ledger.ensure_all!
    say "Created #{inserted} Ledger row(s) for missing (enterprise, contributor) pairs"
  end

  def down
    # No-op — ledgers represent permission-to-write to an enterprise's books
    # for a contributor; removing them on rollback would be destructive.
  end
end
