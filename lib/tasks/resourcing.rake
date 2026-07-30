namespace :resourcing do
  desc "Mirror Runn per-person leave into runn_leaves (nightly)"
  task refresh_runn_leave: :environment do
    count = Resourcing::RunnLeaveRefresh.new.run!
    puts "[resourcing] refreshed runn leave for #{count} people"
  end
end
