ActiveAdmin.register_page "Roles Explorer" do
  menu label: "Roles Explorer", parent: "Team"

  content title: proc { I18n.t("active_admin.roles_explorer") } do
    # Right now, this is hardcoded as a Project Lead role explorer, but in the future it will include
    # UI to explore Technical Lead, Creative Lead & Project Safety Lead role holders.

    admin_users_by_pl_role_last_held =
      AdminUser.active.core.sort { |a,b| b.time_in_days_since_last_project_lead_role <=> a.time_in_days_since_last_project_lead_role }

    plp_sorted_by_ended_at =
      ProjectLeadPeriod.all.sort { |a,b| b.period_ended_at <=> a.period_ended_at }

    h2 "Team by Last Held Project Lead Role"
    table_for(admin_users_by_pl_role_last_held, class: 'index_table') do
      column "Admin User", :admin_user do |admin_user|
        admin_user
      end
      column "Studios", :studios
      column "Time in days since role last held", :time_in_days_since_role_last_held do |admin_user|
        time_in_days = admin_user.time_in_days_since_last_project_lead_role
        if time_in_days.infinite?
          "Never held"
        else
          "#{time_in_days} days"
        end
      end
      column "Aggregate time spent holding role", :aggregate_time_spent_holding_role do |admin_user|
        "#{admin_user.total_time_in_days_holding_project_lead_role} days"
      end
    end

    h2 "All Project Lead Role Holders"
    table_for(plp_sorted_by_ended_at, class: 'index_table') do
      column "Admin User", :admin_user
      column "Studio", :studio
      column "Project Tracker", :project_tracker
      column "Current?", :current? do |plp|
        plp.period_ended_at >= Date.today - 14.days
      end
      column "Started At", :period_started_at
      column "Ended At", :period_ended_at
      column "Time Held", :time_held_in_days do |plp|
        time_held_in_days = plp.time_held_in_days
        "#{time_held_in_days} days"
      end
    end
  end
end