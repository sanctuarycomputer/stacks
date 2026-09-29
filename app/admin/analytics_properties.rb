ActiveAdmin.register AnalyticsProperty do
  menu label: "Site Analytics", parent: "Dashboard"
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :create, :edit, :update, :destroy
  permit_params :name, :ga4_property_id, :site_url, :active

  sidebar "Google Analytics", only: :index do
    if Stacks::GoogleAnalytics.configured?
      para "Synced daily (stacks:daily_enterprise_tasks). A new site backfills 13 months on the next daily run."
    else
      para "Not configured: set GOOGLE_ANALYTICS_SERVICE_ACCOUNT_JSON in Heroku config. Until then nothing syncs."
    end
  end

  index download_links: false, title: "Site Analytics (Google Analytics)" do
    column :name
    column :site_url
    column("GA4 property id") { |p| p.ga4_property_id }
    column :active
    column :data_through
    column :last_synced_at
    column(:last_sync_error) { |p| p.last_sync_error.to_s.truncate(120) }
    actions
  end

  show do
    attributes_table do
      row :name
      row :site_url
      row("GA4 property id") { |p| p.ga4_property_id }
      row :active
      row :data_through
      row :last_synced_at
      row :last_sync_error
      row("Days stored") { |p| p.analytics_daily_metrics.where(breakdown: "total").count }
    end
  end

  form do |f|
    f.inputs do
      f.input :name, hint: "How people will ask for it, e.g. \"garden3d.net\"."
      f.input :site_url
      f.input :ga4_property_id, label: "GA4 property id", hint: "Numeric: GA Admin → Property settings → Property details (not the G- measurement id)."
      f.input :active
    end
    f.actions
  end

  member_action :sync_now, method: :post do
    unless Stacks::GoogleAnalytics.configured?
      redirect_to resource_path, alert: "Not configured: GOOGLE_ANALYTICS_SERVICE_ACCOUNT_JSON is not set."
      next
    end
    # Refresh only: a new site's 13-month backfill runs in the daily task (or rake site_analytics:backfill),
    # never inside this web request.
    outcome = Stacks::SiteAnalyticsSync.new(Stacks::GoogleAnalytics.new).sync_property!(resource, refresh_only: true)
    if outcome == :needs_backfill
      redirect_to resource_path, notice: "No data yet: the next daily run backfills 13 months (or run rake site_analytics:backfill[#{resource.ga4_property_id}])."
    else
      redirect_to resource_path, notice: "Synced: data through #{resource.reload.data_through}"
    end
  rescue Stacks::SiteAnalyticsSync::Busy
    redirect_to resource_path, alert: "Another sync of this site is running; try again in a few minutes."
  rescue StandardError => e
    redirect_to resource_path, alert: "Sync failed (#{e.class}): #{e.message.truncate(300)}"
  end

  action_item :sync_now, only: :show do
    link_to "Sync now", sync_now_admin_analytics_property_path(resource), method: :post
  end
end
