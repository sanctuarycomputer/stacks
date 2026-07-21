namespace :ghost do
  desc "Two-way sync contacts with Ghost (members, source-name labels, funnel sources)"
  task sync: :environment do
    sync = Stacks::GhostSync.sync_all_with_lock!
    if sync
      puts "~~~> Ghost sync complete: #{sync.summary.to_h.inspect}"
      sync.errors.each { |err| puts "~~~> Ghost sync error: #{err}" }
    else
      puts "~~~> Ghost sync skipped: another run holds the advisory lock"
    end
  end
end
