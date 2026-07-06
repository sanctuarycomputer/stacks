ActiveAdmin.register SourceSync do
  menu parent: 'MCP', label: 'ETL: Source syncs', if: proc { current_admin_user&.can_access_etl_admin? }
  actions :index, :show

  # Only Hugh can reach these pages — blocks direct URL navigation, not just the menu.
  controller do
    before_action do
      unless current_admin_user&.can_access_etl_admin?
        redirect_to admin_root_path, alert: "You are not authorized to view that page."
      end
    end
  end

  index do
    id_column
    column :source
    column :last_run_at
    column :status
    column(:stats) { |s| s.stats.to_json }
    actions
  end
end
