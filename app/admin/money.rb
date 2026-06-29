ActiveAdmin.register_page "Money" do
  menu priority: 50

  controller do
    before_action :authenticate_admin_user!

    # The Money tab IS the payable-QBO-bills screen — there's only one page
    # under this tab. Redirect the bare /admin/money so the nav link lands on
    # the actual content instead of an empty register_page skeleton.
    def index
      redirect_to admin_money_payable_qbo_bills_path
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
      flash[:notice] = "Synced #{klass.name} ##{host.id}."
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
