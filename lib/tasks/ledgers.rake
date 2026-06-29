namespace :ledgers do
  desc "Flip every legacy ledger whose balance/unsettled would not change to qbo_bound"
  task migrate_qbo_bound_zero_drift: :environment do
    flipped = 0
    blocked = 0
    errors = 0

    Ledger.where(mode: :legacy).find_each do |ledger|
      result = Ledgers::QboBoundMigrationCheck.call(ledger)
      if result.ready?
        ledger.update!(mode: :qbo_bound)
        flipped += 1
      else
        blocked += 1
      end
    rescue => e
      errors += 1
      warn "Ledger ##{ledger.id}: #{e.class}: #{e.message}"
    end

    puts "Flipped #{flipped} ledgers; #{blocked} still blocked; #{errors} errors."
  end
end
