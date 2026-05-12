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
    helper_method :manual_deel_invoice_visible?

    def scoped_collection
      super.joins(:forecast_person).select("contributors.*, forecast_people.email")
    end

    def find_resource
      # Only preload what's a real ActiveRecord association on Contributor.
      # The *_with_deleted methods route through :ledgers and can't be
      # preloaded by `includes(...)` — they're warmed up via
      # `Contributor#preload_for_ledger_view!` inside the show block instead.
      scoped_collection.includes(
        forecast_person: {
          admin_user: [:full_time_periods, :admin_user_salary_windows],
        },
      ).find(params[:id])
    end

    def manual_deel_invoice_visible?(contributor)
      contributor.deel_invoice_actions_visible_to?(current_admin_user)
    end
  end

  permit_params :qbo_vendor_id, :deel_person_id

  action_item :deel_invoice, only: :show, if: proc {
    manual_deel_invoice_visible?(resource)
  } do
    link_to("New Deel Withdrawal", new_admin_contributor_deel_invoice_adjustment_path(resource))
  end

  action_item :new_contributor_adjustment, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "New Adjustment",
      new_admin_ledger_contributor_adjustment_path(
        Ledger.find_or_create_for(enterprise: Enterprise.sanctuary, contributor: resource)
      )
    )
  end

  action_item :submit_reimbursement, only: :show do
    link_to(
      "Submit Reimbursement",
      new_admin_ledger_reimbursement_path(
        Ledger.find_or_create_for(enterprise: Enterprise.sanctuary, contributor: resource)
      )
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
    # Warm the six *_with_deleted collections so the type-switching loop in
    # the partial doesn't fire N+1 queries. Each method below is memoized
    # per-instance and `preload_for_ledger_view!` populates the caches with
    # eager-loads tailored to the partial's needs.
    resource.preload_for_ledger_view!

    # Resolve which ledger view to render. Default = "all" (aggregated, with elevated_service).
    ledger_param = params[:ledger]

    ledgers_with_items = resource.ledgers.includes(:enterprise).select do |l|
      [l.contributor_payouts, l.contributor_adjustments, l.trueups,
       l.reimbursements, l.profit_shares, l.deel_invoice_adjustments].any?(&:any?)
    end

    view_mode = :all
    current_ledger = nil
    if ledger_param.present? && ledger_param != "all"
      current_ledger = ledgers_with_items.find { |l| l.enterprise.name == ledger_param || l.id.to_s == ledger_param }
      view_mode = :ledger if current_ledger
    end

    items_result =
      if view_mode == :all
        resource.all_items_grouped_by_month
      else
        current_ledger.items_grouped_by_month
      end

    balance = resource.new_deal_balance(items_result)
    admin = resource.forecast_person&.admin_user
    pending_tasks = admin&.pending_tasks || []

    render(partial: "show", locals: {
      contributor: resource,
      items_result: items_result,
      new_deal_ledger_items: items_result,
      balance: balance,
      pending_tasks: pending_tasks,
      view_mode: view_mode,
      ledgers_with_items: ledgers_with_items,
      current_ledger: current_ledger,
    })
  end
end
