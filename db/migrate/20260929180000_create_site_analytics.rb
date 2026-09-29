# Google Analytics (GA4) for our own sites: a small admin-edited list of properties, and the daily
# metrics Stacks syncs for each (Stacks::SiteAnalyticsSync), read by the get_site_analytics MCP tool.
# A site is just a site: nothing here links to a studio (one company, 2026-09-29).
class CreateSiteAnalytics < ActiveRecord::Migration[6.1]
  def change
    create_table :analytics_properties do |t|
      t.string :name, null: false
      t.string :ga4_property_id, null: false
      t.string :site_url
      t.boolean :active, null: false, default: true
      t.date :data_through
      t.datetime :last_synced_at
      t.text :last_sync_error
      t.timestamps
    end
    add_index :analytics_properties, :ga4_property_id, unique: true
    add_index :analytics_properties, :name, unique: true

    # One row per property × date × breakdown × dimension values. breakdown is "total" (no dimensions),
    # "traffic" (source / medium / campaign) or "landing_page". Rows past each day's top N fold into one
    # "(other)" row, so every breakdown still sums to the day's total. Rewritten per (property, date,
    # breakdown) by delete + insert, so there is no unique index over the (long) dimension values.
    create_table :analytics_daily_metrics do |t|
      t.references :analytics_property, null: false, foreign_key: { on_delete: :cascade }
      t.date :date, null: false
      t.string :breakdown, null: false
      t.string :source, null: false, default: ""
      t.string :medium, null: false, default: ""
      t.string :campaign, null: false, default: ""
      t.string :landing_page, null: false, default: ""
      t.integer :sessions, null: false, default: 0
      t.integer :total_users, null: false, default: 0
      t.integer :new_users, null: false, default: 0
      t.integer :views, null: false, default: 0
      t.integer :engaged_sessions, null: false, default: 0
      t.decimal :key_events, precision: 14, scale: 2, null: false, default: 0
      t.timestamps
    end
    add_index :analytics_daily_metrics, [:analytics_property_id, :breakdown, :date], name: "index_analytics_daily_metrics_lookup"
  end
end
