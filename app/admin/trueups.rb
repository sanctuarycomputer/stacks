ActiveAdmin.register Trueup do
  config.filters = false
  config.paginate = false
  actions :index, :show, :destroy
  menu false

  belongs_to :ledger

  index download_links: false do
    column :contributor
    column :amount
    column :payment_date
    actions
  end

  action_item :sync_qbo_bill, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Sync QBO Bill", sync_qbo_bill_admin_ledger_trueup_path(resource.ledger, resource),
      method: :post
  end

  member_action :sync_qbo_bill, method: :post do
    tu = Trueup.find(params[:id])
    tu.sync_qbo_bill!
    return redirect_to(
      admin_ledger_trueup_path(tu.ledger, tu),
      notice: "Success",
    )
  rescue Qbo::UnmappedLineItemError => e
    # Unmapped is an expected operational state (new enterprise, pre-seed
    # window) — surface the actionable message instead of a 500.
    redirect_to admin_ledger_trueup_path(tu.ledger, tu), alert: e.message
  end

  show do
    render(partial: 'show', locals: {
      resource: resource
    })
  end
end
