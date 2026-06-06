ActiveAdmin.register Contributor do
  menu parent: "Team"

  config.filters = true
  config.paginate = true
  config.per_page = 20
  config.sort_order = "forecast_people.email_asc"

  actions :index, :show, :edit, :update
  scope "Recent Contributors", :recent_contributors, default: true
  scope :all

  filter :forecast_email_cont, as: :string, label: "Email contains"

  controller do
    helper_method :manual_deel_invoice_visible?

    def scoped_collection
      # Preload the per-enterprise vendor mappings so the index column can
      # render one badge per (enterprise, vendor) without an N+1.
      super.joins(:forecast_person)
        .select("contributors.*, forecast_people.email")
        .preload(contributor_qbo_vendors: [:qbo_vendor, { qbo_account: :enterprise }])
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

  permit_params :deel_person_id,
    contributor_qbo_vendors_attributes: [:id, :qbo_vendor_id, :_destroy]

  # Action items below are scoped to the ledger tab the user is viewing.
  # On the "All" tab (no `ledger` query param), there's no single ledger to
  # write against, so the buttons short-circuit to a JS alert instead.
  LEDGER_REQUIRED_ALERT = "Select the appropriate ledger before you can perform this action.".freeze

  action_item :deel_invoice, only: :show, if: proc {
    manual_deel_invoice_visible?(resource)
  } do
    selected_ledger = params[:ledger].present? && resource.ledgers.find_by(id: params[:ledger])
    if selected_ledger
      link_to "New Deel Withdrawal",
        new_admin_contributor_deel_invoice_adjustment_path(resource, ledger: selected_ledger.id)
    else
      link_to "New Deel Withdrawal", "#",
        onclick: "alert(#{LEDGER_REQUIRED_ALERT.to_json}); return false;"
    end
  end

  action_item :new_contributor_adjustment, only: :show, if: proc { current_admin_user.is_admin? } do
    selected_ledger = params[:ledger].present? && resource.ledgers.find_by(id: params[:ledger])
    if selected_ledger
      link_to "New Adjustment", new_admin_ledger_contributor_adjustment_path(selected_ledger)
    else
      link_to "New Adjustment", "#",
        onclick: "alert(#{LEDGER_REQUIRED_ALERT.to_json}); return false;"
    end
  end

  action_item :request_payment, only: :show do
    selected_ledger = params[:ledger].present? && resource.ledgers.find_by(id: params[:ledger])
    if selected_ledger
      link_to "Request Payment",
        new_admin_ledger_withdrawal_request_path(ledger_id: selected_ledger.id)
    else
      link_to "Request Payment", "#",
        onclick: "alert(#{LEDGER_REQUIRED_ALERT.to_json}); return false;"
    end
  end

  action_item :submit_reimbursement, only: :show do
    selected_ledger = params[:ledger].present? && resource.ledgers.find_by(id: params[:ledger])
    if selected_ledger
      link_to "Submit Reimbursement", new_admin_ledger_reimbursement_path(selected_ledger)
    else
      link_to "Submit Reimbursement", "#",
        onclick: "alert(#{LEDGER_REQUIRED_ALERT.to_json}); return false;"
    end
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
      f.input :deel_person
    end

    # One row per (enterprise, qbo_vendor) mapping. Per-enterprise scoping is
    # enforced server-side: the join row's qbo_account_id is derived from the
    # chosen vendor's qbo_account_id in a ContributorQboVendor before_validation
    # callback, so the admin only needs to pick a vendor.
    f.has_many :contributor_qbo_vendors,
               heading: "Per-enterprise QBO vendor mappings",
               allow_destroy: true,
               new_record: "Add QBO vendor mapping" do |cqv|
      vendor_options = QboVendor.includes(qbo_account: :enterprise).all.sort_by do |qv|
        [qv.qbo_account&.enterprise&.name.to_s, qv.display_name.to_s]
      end.map do |qv|
        enterprise_label = qv.qbo_account&.enterprise&.name || "(no enterprise)"
        ["#{enterprise_label}: #{qv.display_name}", qv.id]
      end
      cqv.input :qbo_vendor,
        as: :select,
        collection: vendor_options,
        include_blank: "Choose a QBO vendor…",
        label: "QBO vendor"
    end

    f.actions
  end

  index download_links: false do
    column :forecast_person
    column "QBO Vendors" do |c|
      cqvs = c.contributor_qbo_vendors.to_a
      if cqvs.empty?
        "—"
      else
        # `status_tag` is an Arbre element that side-effects into the current
        # cell, so returning a `safe_join(status_tags)` from the column block
        # ends up rendering each badge twice (once from the side effect, once
        # from the explicit return — see ActiveAdmin table_for.rb#build_table_cell).
        # `content_tag(:span, ..., class: "status_tag")` is a pure string
        # builder and doesn't double up.
        safe_join(cqvs.sort_by { |cqv| cqv.qbo_account&.enterprise&.name.to_s }.map { |cqv|
          enterprise_label = cqv.qbo_account&.enterprise&.name || "(no enterprise)"
          vendor_label = cqv.qbo_vendor&.display_name || "(no vendor)"
          content_tag(:span, "#{enterprise_label}: #{vendor_label}", class: "status_tag")
        }, " ")
      end
    end
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

    # Show every enterprise tab regardless of activity — a contributor needs to
    # be able to navigate to an empty ledger to file a reimbursement, accept a
    # pay stub, etc. Sorted by enterprise name for stable display.
    ledgers = resource.ledgers.includes(:enterprise).sort_by { |l| l.enterprise.name.to_s }

    view_mode = :all
    current_ledger = nil
    if ledger_param.present? && ledger_param != "all"
      current_ledger = ledgers.find { |l| l.id.to_s == ledger_param.to_s }
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
      ledgers: ledgers,
      current_ledger: current_ledger,
    })
  end
end
