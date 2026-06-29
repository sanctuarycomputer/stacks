ActiveAdmin.register_page "Money" do
  menu priority: 50

  controller do
    before_action :authenticate_admin_user!
    before_action :verify_admin!

    # The Money tab IS the payable-QBO-bills screen — there's only one page
    # under this tab. Redirect the bare /admin/money so the nav link lands on
    # the actual content instead of an empty register_page skeleton.
    def index
      redirect_to admin_money_payable_qbo_bills_path
    end

    private

    # Cross-enterprise AP totals + admin-only sync_qbo_bill! triggers are
    # staff-only. Without this gate, any logged-in AdminUser (including the
    # contributor-linked AdminUsers our admin app supports) could load every
    # enterprise's payable bills and POST refresh actions. Non-admins land on
    # invoice_passes — the same destination the Money nav historically forwarded
    # everyone to before this PR, so the nav link still works for contributors.
    def verify_admin!
      return if current_admin_user&.is_admin?
      redirect_to admin_invoice_passes_path, alert: "Admins only."
    end
  end

  page_action :payable_qbo_bills, method: :get do
    @qbo_accounts = QboAccount.includes(:enterprise).sort_by { |qa| qa.enterprise.name.to_s }
    @active_qa = params[:qbo_account_id].present? ? QboAccount.find(params[:qbo_account_id]) : nil

    # ONE pass per QboAccount — both payable rows and unsettled totals come
    # back in a single Stats object. Drives (a) the active view's table,
    # (b) the "All" view's aggregate, (c) the red notifier dots on every
    # enterprise tab, and (d) the summary card's Total Unsettled.
    @summary_by_account = @qbo_accounts.index_with { |qa| Money::QboBillSummary.call(qbo_account: qa) }
    @rows_by_account = @summary_by_account.transform_values(&:payable_rows)
    @rows = @active_qa ? @rows_by_account[@active_qa] : @rows_by_account.values.flatten

    accounts_in_scope = @active_qa ? [@active_qa] : @qbo_accounts
    @unsettled_total = accounts_in_scope.sum { |qa| @summary_by_account[qa].unsettled_total }
    @unsettled_count = accounts_in_scope.sum { |qa| @summary_by_account[qa].unsettled_count }

    render "admin/money/payable_qbo_bills"
  end

  page_action :refresh_bill, method: :post do
    # Guard the host_class lookup BEFORE constantize so an unknown string can't
    # raise NameError (which would surface as 500 instead of BadRequest).
    raw_class = params.require(:host_class).to_s
    raise ActionController::BadRequest, "unsupported host class" unless Money::PayableQboBills::HOST_KLASSES.map(&:name).include?(raw_class)
    klass = raw_class.constantize
    host = klass.find(params.require(:host_id))
    begin
      host.sync_qbo_bill!
      host.reload
      if host.qbo_bill_id.present?
        flash[:notice] = "Synced #{klass.name} ##{host.id}."
      else
        # sync_qbo_bill! silently returns nil when there's no QBO account, no
        # vendor mapping, or amount <= 0. Don't pretend it succeeded — tell
        # the operator what to fix so they don't loop clicking Sync.
        flash[:alert] = "No-op: #{klass.name} ##{host.id} didn't create a QBO bill. Likely missing vendor mapping, no QBO account, or non-positive amount."
      end
    rescue => e
      Rails.logger.error("[refresh_bill] qbo_account=#{params[:qbo_account_id]} host=#{klass.name}##{host.id}: #{e.class}: #{e.message}")
      flash[:alert] = "Sync failed for #{klass.name} ##{host.id}: #{e.message}"
    end
    redirect_back(fallback_location: admin_money_payable_qbo_bills_path(qbo_account_id: params[:qbo_account_id]))
  end

  # Refresh-all: when scoped to a tab, refreshes that account's bills; when on
  # the "All" tab (no qbo_account_id), refreshes every connected account. Per-row
  # failures inside RefreshPayableQboBills are rescued and returned as an array
  # so we can surface a single aggregated alert to the admin instead of a 500.
  page_action :refresh_tab, method: :post do
    failures =
      if params[:qbo_account_id].present?
        qa = QboAccount.find(params[:qbo_account_id])
        Money::RefreshPayableQboBills.call(qbo_account: qa)
      else
        QboAccount.find_each.flat_map { |qa| Money::RefreshPayableQboBills.call(qbo_account: qa) }
      end

    if failures.any?
      preview = failures.first(3).map { |host, e| "#{host.class.name}##{host.id} (#{e.class})" }.join(", ")
      flash[:alert] = "#{failures.size} bill#{"s" if failures.size != 1} failed to sync — see logs. Examples: #{preview}#{"…" if failures.size > 3}"
    else
      flash[:notice] = "Synced all bills on this view."
    end
    redirect_back(fallback_location: admin_money_payable_qbo_bills_path(qbo_account_id: params[:qbo_account_id]))
  end
end
