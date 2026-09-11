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

    desc "Notion mirror: one-off, resumable full load of pages, data sources, schemas and seed trees"
    task backfill: :environment do
      system_task = SystemTask.create!(name: "stacks:notion:backfill")
      begin
        stats = Stacks::Notion::Backfill.run_with_lock!
        Rails.logger.info(stats ? "[stacks:notion:backfill] #{stats.inspect}" : "[stacks:notion:backfill] skipped: lock held")
        puts stats.inspect if stats
      rescue => e
        system_task.mark_as_error(e)
        raise # a one-off `heroku run` must exit non-zero so the operator re-runs it
      else
        system_task.mark_as_success
      end
    end

    desc "Notion mirror: daily full-feed reconcile (trash / access-lost / drift)"
    task reconcile: :environment do
      system_task = SystemTask.create!(name: "stacks:notion:reconcile")
      begin
        stats = Stacks::Notion::Reconcile.run_with_lock!
        Rails.logger.info(stats ? "[stacks:notion:reconcile] #{stats.inspect}" : "[stacks:notion:reconcile] skipped: lock held")
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end
  end
end
