ActiveAdmin.register OptixOrganization do
  menu parent: "Optix", priority: 1
  config.filters = false
  config.paginate = false
  actions :index, :show, :new, :create, :destroy
  permit_params :name, :optix_id

  action_item :resync, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Resync now",
      resync_admin_optix_organization_path(resource),
      method: :post,
      data: { confirm: "Pull every location, plan template, user, and account plan from Optix into the local DB? Safe to re-run." }
  end

  member_action :resync, method: :post do
    begin
      Stacks::OptixSync.new(resource).sync_all!
      redirect_to admin_optix_organization_path(resource), notice: "Optix sync completed at #{resource.reload.synced_at}."
    rescue => e
      redirect_to admin_optix_organization_path(resource), alert: "Sync failed: #{e.class}: #{e.message}"
    end
  end

  index do
    column :name
    column :optix_id
    column "Last Synced", :synced_at
    column "Locations" do |o|
      o.optix_locations.count
    end
    column "Plan Templates" do |o|
      o.optix_plan_templates.count
    end
    column "Users" do |o|
      o.optix_users.count
    end
    column "Account Plans" do |o|
      o.optix_account_plans.count
    end
    actions
  end

  show do
    attributes_table do
      row :id
      row :name
      row :optix_id
      row :synced_at
      row :created_at
      row :updated_at
    end

    panel "Counts" do
      table_for [resource] do
        column "Locations" do |o|
          link_to o.optix_locations.count, admin_optix_locations_path(q: { optix_organization_id_eq: o.id })
        end
        column "Plan Templates" do |o|
          link_to o.optix_plan_templates.count, admin_optix_plan_templates_path(q: { optix_organization_id_eq: o.id })
        end
        column "Users" do |o|
          link_to o.optix_users.count, admin_optix_users_path(q: { optix_organization_id_eq: o.id })
        end
        column "Active Members" do |o|
          link_to o.active_members.count, admin_optix_users_path(q: { optix_organization_id_eq: o.id })
        end
        column "Account Plans" do |o|
          link_to o.optix_account_plans.count, admin_optix_account_plans_path(q: { optix_organization_id_eq: o.id })
        end
        column "Active Plans" do |o|
          link_to o.optix_account_plans.paying.count,
            admin_optix_account_plans_path(q: { optix_organization_id_eq: o.id, status_in: %w[ACTIVE IN_TRIAL] })
        end
      end
    end

    panel "Weekly Membership Snapshot — paste-ready for Google Sheets" do
      para "Select rows in the table below, ⌘+C to copy, paste into your spreadsheet. Date format and number cells map directly to Sheets columns."
      snapshots = (resource.weekly_membership_snapshots(weeks: 16) rescue [])
      if snapshots.any?
        table_for snapshots do
          column("Week End") { |r| r[:week_end].strftime("%-m/%-d/%y") }
          column("Location") { |r| r[:location] }
          column("Active Non-Patron Members") { |r| r[:non_patron] }
          column("Patron Members") { |r| r[:patron] }
          column("Total Members") { |r| r[:total] }
        end
      else
        para "No data yet — run a sync to populate."
      end
    end

    histories = (resource.membership_history_by_location(months: 12) rescue {})
    histories.each do |location_name, rows|
      panel "Month-over-month membership — #{location_name} (last 12 months)" do
        if rows.any?
          table_for rows do
            column("Month") { |row| row[:month].strftime("%b %Y") }
            column("Active") { |row| row[:active_count] }
            column("New") { |row| row[:new_count] }
            column("Churned") { |row| row[:churned_count] }
            column("Net change") { |row|
              v = row[:net_change]
              color = v > 0 ? "green" : (v < 0 ? "red" : "inherit")
              content_tag(:span, (v > 0 ? "+#{v}" : v.to_s), style: "color: #{color};")
            }
          end
        else
          para "No data yet — run a sync to populate."
        end
      end
    end

    panel "Members by tier (current, org-wide)" do
      tier_counts = resource.optix_account_plans.paying
        .joins(:optix_plan_template)
        .group("optix_plan_templates.name", "optix_plan_templates.in_all_locations")
        .count

      if tier_counts.any?
        rows = tier_counts.map { |(tier, in_all), n|
          { tier: tier, scope: in_all ? "All Locations" : "Specific locations", count: n }
        }.sort_by { |r| [r[:tier] || ""] }
        table_for rows do
          column("Tier") { |r| r[:tier] }
          column("Available at") { |r| r[:scope] }
          column("Count") { |r| r[:count] }
        end
      else
        para "No active members yet — run a sync to populate."
      end
    end

    panel "Members by tier × location (current)" do
      # Plans tied to specific locations through the join table.
      by_location = resource.optix_account_plans.paying
        .joins(optix_plan_template: :optix_locations)
        .group("optix_locations.name", "optix_plan_templates.name")
        .count

      # Plans flagged in_all_locations don't appear in the join table; surface
      # them under their own pseudo-location bucket so they're not silently
      # missing from the breakdown.
      in_all = resource.optix_account_plans.paying
        .joins(:optix_plan_template)
        .where(optix_plan_templates: { in_all_locations: true })
        .group("optix_plan_templates.name")
        .count

      rows = by_location.map { |(loc, tier), n| { location: loc, tier: tier, count: n } }
      rows.concat(in_all.map { |tier, n| { location: "All Locations", tier: tier, count: n } })

      if rows.any?
        table_for rows.sort_by { |r| [r[:location] || "", r[:tier] || ""] } do
          column("Location") { |r| r[:location] }
          column("Tier") { |r| r[:tier] }
          column("Count") { |r| r[:count] }
        end
      else
        para "No location-scoped data — likely zero locations synced. See \"Members by tier (org-wide)\" above for the totals that DO exist."
      end
    end
  end

  form do |f|
    f.inputs do
      f.input :name
      f.input :optix_id, hint: "Optional — Optix's own organization id, if known."
    end
    f.actions
  end
end
