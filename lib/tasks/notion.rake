namespace :stacks do
  namespace :notion do
    desc "Notion mirror: walk the search feed and refresh stale block trees (every 10 min)"
    task sweep: :environment do
      system_task = SystemTask.create!(name: "stacks:notion:sweep")
      begin
        stats = Stacks::Notion::Sweep.run_with_lock!
        Rails.logger.info(stats ? "[stacks:notion:sweep] #{stats.inspect}" : "[stacks:notion:sweep] skipped: lock held")
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end
  end
end
