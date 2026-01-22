ActiveAdmin.register Trueup do
  config.filters = false
  config.paginate = false
  actions :index, :show, :destroy
  menu false

  belongs_to :contributor

  index download_links: false do
    column :contributor
    column :amount
    column :payment_date
    actions
  end

  action_item :sync_qbo_bill, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Sync QBO Bill", sync_qbo_bill_admin_contributor_trueup_path(resource.contributor, resource),
      method: :post
  end

  member_action :sync_qbo_bill, method: :post do
    tu = Trueup.find(params[:id])
    tu.sync_qbo_bill!
    return redirect_to(
      admin_contributor_trueup_path(tu.contributor, tu),
      notice: "Success",
    )
  end

  show do
    render(partial: 'show', locals: {
      resource: resource
    })
  end
end
