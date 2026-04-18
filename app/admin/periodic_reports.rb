ActiveAdmin.register PeriodicReport do
  menu parent: "Dashboard", label: "Quarterly Reports"

  config.filters = false
  config.paginate = false
  config.sort_order = "period_starts_at_desc"
  actions :index, :show, :edit, :update
  scope :all

  permit_params :report_url

  controller do
    def action_methods
      return super if current_admin_user.is_admin?
      super - %w[edit update sync_profit_shares]
    end

    before_action :require_admin_to_edit_periodic_report, only: [:edit, :update]
    before_action :require_admin_to_sync_profit_shares, only: [:sync_profit_shares]

    private

    def require_admin_to_edit_periodic_report
      return if current_admin_user.is_admin?
      redirect_to admin_periodic_report_path(params[:id]), alert: "Only admins can edit quarterly reports."
    end

    def require_admin_to_sync_profit_shares
      return if current_admin_user.is_admin?
      redirect_to admin_periodic_report_path(params[:id]), alert: "Only admins can sync profit shares."
    end
  end

  action_item :sync_profit_shares, only: :show, if: proc { current_admin_user.is_admin? } do
    opts = {}
    opts[:studio] = params[:studio] if params[:studio].present?
    link_to "Sync profit shares", sync_profit_shares_admin_periodic_report_path(resource, opts), method: :post
  end

  member_action :sync_profit_shares, method: :post do
    skipped = resource.profit_shares.any? && resource.all_profit_shares_accepted?
    resource.sync_profit_shares!
    resource.reload
    redirect_opts = { studio: params[:studio].presence }.compact
    if skipped
      redirect_to admin_periodic_report_path(resource, redirect_opts), notice: "Sync skipped: all profit shares already accepted."
    elsif resource.notification.present?
      redirect_to admin_periodic_report_path(resource, redirect_opts), alert: "Sync recorded an error. Check the notification on this report."
    else
      redirect_to admin_periodic_report_path(resource, redirect_opts), notice: "Sync completed."
    end
  end

  index do
    column :period_label
    column :profit_share_status do |resource|
      status =
        if resource.profit_shares.empty?
          resource.notification.present? ? "error" : "not_generated"
        else
          resource.all_profit_shares_accepted? ? "all_accepted" : "some_pending"
        end

      span(status.humanize, class: "pill #{status}")
    end
    column :generated_at do |resource|
      resource.blueprint["generated_at"]
    end
    column "Ext. report" do |resource|
      resource.report_url.present? ? span("Yes", class: "pill complete") : span("—", class: "pill")
    end
    actions defaults: false do |pr|
      links = [link_to("View", admin_periodic_report_path(pr))]
      links << link_to("Edit", edit_admin_periodic_report_path(pr)) if current_admin_user.is_admin?
      safe_join(links, " | ")
    end
  end

  form do |f|
    f.inputs do
      f.input :report_url, hint: "Link to the written quarterly report (Google Doc, internal wiki, etc.)"
    end
    f.actions
  end

  show do
    # Prefer raw query string so tab matches what the browser sent (same source as `quarter_slice` below).
    raw_studio = params[:studio].presence || controller.request.query_parameters["studio"]
    norm = raw_studio.to_s.downcase.strip
    scope_param = PeriodicReport::STUDIO_TAB_KEYS.include?(norm) ? norm : "g3d"
    scope_studio = PeriodicReport.scope_studio_from_param(scope_param)
    accounting_method = session[:accounting_method] || "cash"
    quarter_slice = resource.quarter_slice_for_studio(scope_studio)
    collective_okrs = resource.collective_okrs_for_studio_tab(accounting_method, scope_param, scope_studio)
    filtered_shares = resource.profit_shares_for_studio(scope_studio)
    filtered_total_shares = filtered_shares.sum { |ps| ps.blueprint&.dig("shares").to_f }

    studio_tabs =
      PeriodicReport::STUDIO_TAB_KEYS.map do |key|
        tab_studio = PeriodicReport.scope_studio_from_param(key)
        { key: key, label: tab_studio&.name.presence || key.humanize }
      end

    render(partial: "show", locals: {
      periodic_report: resource,
      scope_studio: scope_studio,
      scope_param: scope_param,
      accounting_method: accounting_method,
      quarter_slice: quarter_slice,
      collective_okrs: collective_okrs,
      filtered_profit_shares: filtered_shares,
      filtered_total_shares: filtered_total_shares,
      studio_tabs: studio_tabs,
    })
  end
end
