namespace :stacks do
  namespace :etl do
    desc 'Ongoing Google Meet transcript sync (Meet REST API)'
    task sync_meet: :environment do
      system_task = SystemTask.create!(name: 'stacks:etl:sync_meet')
      begin
        admin = Stacks::Utils.config.dig(:google_oauth2, :admin_email) || 'hugh@sanctuary.computer'
        Stacks::Etl::Meet::Connector.new(admin_email: admin, mode: :api).run
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end

    desc 'Backfill Google Meet transcripts from Drive (default 90 days)'
    task :backfill_meet, [:days] => :environment do |_t, args|
      system_task = SystemTask.create!(name: 'stacks:etl:backfill_meet')
      begin
        days = (args[:days] || 90).to_i
        admin = Stacks::Utils.config.dig(:google_oauth2, :admin_email) || 'hugh@sanctuary.computer'
        Stacks::Etl::Meet::Connector.new(admin_email: admin, mode: :drive, since: days.days.ago).run
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end
  end
end
