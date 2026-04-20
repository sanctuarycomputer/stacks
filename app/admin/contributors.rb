ActiveAdmin.register Contributor do
  menu parent: "Team"

  config.filters = true
  config.paginate = true
  config.per_page = 20
  config.sort_order = "forecast_people.email_asc"

  actions :index, :show, :edit, :update
  scope :recent_new_deal_contributors, default: true
  scope :all

  filter :forecast_email_cont, as: :string, label: "Email contains"

  controller do
    def scoped_collection
      super.joins(:forecast_person).select("contributors.*, forecast_people.email")
    end

    def find_resource
      scoped_collection.includes(
        forecast_person: {
          admin_user: [:full_time_periods, :admin_user_salary_windows],
        },
        contributor_payouts_with_deleted: {
          invoice_tracker: [:invoice_pass, :contributor_payouts, :forecast_client, :qbo_invoice],
        },
        profit_shares_with_deleted: { periodic_report: :profit_shares },
        contributor_adjustments_with_deleted: :qbo_invoice,
        trueups_with_deleted: :invoice_pass,
      ).find(params[:id])
    end
  end

  permit_params :qbo_vendor_id, :deel_person_id

  action_item :record_misc_payment, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "Record Misc Payment",
      new_admin_contributor_misc_payment_path(resource)
    )
  end

  action_item :new_contributor_adjustment, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "New Adjustment",
      new_admin_contributor_contributor_adjustment_path(resource)
    )
  end

  action_item :submit_reimbursement, only: :show do
    link_to(
      "Submit Reimbursement",
      new_admin_contributor_reimbursement_path(resource)
    )
  end

  member_action :toggle_contributor_payout_acceptance, method: :post do
    cp = ContributorPayout.find(params[:contributor_payout_id])
    return unless cp.contributor.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
    cp.toggle_acceptance!
    return redirect_to(
      admin_contributor_path(params[:id], format: :html),
      notice: "Success",
    )
  end

  member_action :toggle_profit_share_acceptance, method: :post do
    ps = ProfitShare.find(params[:profit_share_id])
    return unless ps.contributor.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
    ps.toggle_acceptance!
    return redirect_to(
      admin_contributor_path(params[:id], format: :html),
      notice: "Success",
    )
  end

  member_action :toggle_reimbursement_acceptance, method: :post do
    r = Reimbursement.find(params[:reimbursement_id])
    return unless current_admin_user.is_admin?

    if r.accepted?
      r.update!(
        accepted_by: nil,
        accepted_at: nil
      )
    else
      r.update!(
        accepted_by: current_admin_user,
        accepted_at: DateTime.now
      )
    end

    return redirect_to(
      admin_contributor_path(params[:id], format: :html),
      notice: "Success",
    )
  end

  form do |f|
    f.inputs do
      f.input :forecast_person, input_html: { disabled: true }
      f.input :qbo_vendor
      f.input :deel_person
    end
    f.actions
  end

  index download_links: false do
    column :forecast_person
    column :qbo_vendor
    column :deel_person
    # column :balance do |c|
    #   balance = c.new_deal_balance
    #   if balance[:unsettled] > 0
    #     "#{number_to_currency(balance[:balance])} (#{number_to_currency(balance[:unsettled])} unsettled)"
    #   else
    #     number_to_currency(balance[:balance])
    #   end
    # end
    # if current_admin_user.is_hugh?
    #   column :total_amount_paid do |resource|
    #     number_to_currency(resource.total_amount_paid[:total])
    #   end
    # end
    actions
  end

  show do
    new_deal_ledger_items = resource.new_deal_ledger_items
    balance = resource.new_deal_balance(new_deal_ledger_items)
    admin = resource.forecast_person&.admin_user
    pending_tasks = admin&.pending_tasks || []

    render(partial: "show", locals: {
      contributor: resource,
      new_deal_ledger_items: new_deal_ledger_items,
      balance: balance,
      pending_tasks: pending_tasks,
    })
  end
end
