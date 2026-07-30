namespace :resourcing do
  desc "Mirror Runn per-person leave into runn_leave_mirrors (nightly)"
  task refresh_leave_mirror: :environment do
    count = Resourcing::LeaveMirrorRefresh.new.run!
    puts "[resourcing] refreshed leave mirror for #{count} people"
  end
end
