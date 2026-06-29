namespace :reimbursements do
  desc "Push every accepted Reimbursement to QBO that hasn't synced yet"
  task backfill_qbo_bills: :environment do
    synced = 0
    skipped = 0
    errors = 0

    # Filter to ledgers with 'qbo' in payment_methods so we don't push a Bill
    # on top of an already-planned Deel payout — see Contributor#sync_qbo_bills!
    # for the same gate.
    Reimbursement
      .where.not(accepted_by_id: nil)
      .where(qbo_bill_id: nil)
      .joins(:ledger)
      .where("'qbo' = ANY(ledgers.payment_methods)")
      .find_each do |r|
      r.sync_qbo_bill!
      if r.reload.qbo_bill_id.present?
        synced += 1
      else
        # sync_qbo_bill! short-circuits silently when the contributor has no
        # ContributorQboVendor mapping or the enterprise has no QBO account.
        skipped += 1
      end
    rescue => e
      errors += 1
      warn "Reimbursement ##{r.id}: #{e.class}: #{e.message}"
    end

    puts "Synced #{synced} reimbursements; #{skipped} skipped (missing mapping); #{errors} errors."
  end
end
