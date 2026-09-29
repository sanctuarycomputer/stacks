namespace :site_analytics do
  desc "Sync Google Analytics (GA4) daily metrics for every active site (also runs in stacks:daily_enterprise_tasks)"
  task sync: :environment do
    result = Stacks::SiteAnalyticsSync.sync_all_with_lock!
    puts(result.nil? ? "skipped: another sync holds the lock" : result.inspect)
  end

  desc "Add every GA4 property the service account can see as a site (never deletes)"
  task discover: :environment do
    puts "created: #{Stacks::SiteAnalyticsSync.new(Stacks::GoogleAnalytics.new).discover!.inspect}"
  end

  desc "Re-backfill one site: rake site_analytics:backfill[<ga4 property id>,<months, default 13>]"
  task :backfill, [:property_id, :months] => :environment do |_t, args|
    prop = AnalyticsProperty.find_by!(ga4_property_id: args[:property_id].to_s)
    months = (args[:months] || Stacks::SiteAnalyticsSync::BACKFILL_MONTHS).to_i
    Stacks::SiteAnalyticsSync.new(Stacks::GoogleAnalytics.new).backfill!(prop, months: months)
    puts "#{prop.name}: data through #{prop.reload.data_through}"
  rescue Stacks::SiteAnalyticsSync::Busy => e
    puts "skipped: #{e.message}"
  end
end
