ActiveAdmin.register_page "Money" do
  menu priority: 50

  controller do
    before_action :authenticate_admin_user!
  end

  page_action :payable_qbo_bills, method: :get do
    @qbo_accounts = QboAccount.includes(:enterprise).order(:id).to_a
    @active_qa = if params[:qbo_account_id].present?
      QboAccount.find(params[:qbo_account_id])
    else
      @qbo_accounts.first
    end
    @rows = @active_qa ? Money::PayableQboBills.call(qbo_account: @active_qa) : []
    render "admin/money/payable_qbo_bills"
  end

  page_action :refresh_bill, method: :post do
    klass = params.require(:host_class).to_s.constantize
    raise ActionController::BadRequest, "unsupported host class" unless Money::PayableQboBills::HOST_KLASSES.include?(klass)
    host = klass.find(params.require(:host_id))
    host.sync_qbo_bill!
    redirect_back(fallback_location: admin_money_payable_qbo_bills_path(qbo_account_id: params[:qbo_account_id]))
  end

  page_action :refresh_tab, method: :post do
    qa = QboAccount.find(params.require(:qbo_account_id))
    Money::RefreshPayableQboBills.call(qbo_account: qa)
    redirect_back(fallback_location: admin_money_payable_qbo_bills_path(qbo_account_id: qa.id))
  end
end
