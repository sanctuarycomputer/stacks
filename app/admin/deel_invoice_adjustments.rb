ActiveAdmin.register DeelInvoiceAdjustment do
  belongs_to :contributor
  menu false
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :show

  permit_params :deel_contract_id, :amount, :description, :date_submitted, :allow_ledger_overdraw

  controller do
    helper_method :deel_invoice_overdraw_checkbox_visible?

    before_action :verify_deel_invoice_access!, only: [:index, :new, :create, :show]

    def deel_invoice_overdraw_checkbox_visible?
      current_admin_user.roles.include?("admin")
    end

    def skip_balance_validation_for_request?(submitted)
      return false unless current_admin_user.roles.include?("admin")

      ActiveModel::Type::Boolean.new.cast(submitted[:allow_ledger_overdraw])
    end

    def manual_deel_invoice_submission_allowed?(contributor)
      contributor.deel_invoice_actions_visible_to?(current_admin_user)
    end

    def verify_deel_invoice_access!
      # :new / :create / :index / :show all share the same predicate —
      # `deel_invoice_actions_visible_to?` permits both staff admins AND the
      # contributor's own linked AdminUser, so a contributor can self-submit
      # a Deel withdrawal from their own contributor page. Earlier hard-coding
      # to `is_admin?` here silently broke that self-submit path.
      unless manual_deel_invoice_submission_allowed?(parent)
        redirect_to admin_contributor_path(parent), alert: "That action is not available."
        return
      end

      # On :new / :create, also enforce that the target ledger has 'deel' in
      # payment_methods. The UI button is already gated, but a direct POST
      # (deep link, stale bookmark) could otherwise land a DIA on a qbo_bound
      # ledger — audit_only_under_qbo_bound? would silently filter it from
      # both balance and unsettled, so the contributor's recorded Deel
      # withdrawal never deducts from their Stacks balance.
      if [:new, :create].include?(action_name.to_sym)
        target_ledger =
          if params[:ledger].present?
            parent.ledgers.find_by(id: params[:ledger])
          elsif params.dig(:deel_invoice_adjustment, :ledger_id).present?
            parent.ledgers.find_by(id: params[:deel_invoice_adjustment][:ledger_id])
          else
            # No explicit ledger param: build_resource / create fall back to
            # the contributor's Sanctuary ledger. Resolve THAT here so the
            # deel-enabled check covers the fallback path too (otherwise a
            # contributor self-submit with no ledger param would silently
            # land on a qbo_bound Sanctuary ledger).
            Ledger.find_by(enterprise: Enterprise.sanctuary, contributor: parent)
          end
        if target_ledger && !target_ledger.deel_enabled?
          redirect_to admin_contributor_path(parent),
            alert: "Deel is not enabled for this ledger's payment methods."
          return
        end
      end
    end

    def show
      case DeelInvoiceAdjustments::SyncFromDeel.call(resource)
      when :removed
        redirect_to admin_contributor_path(parent),
          notice: "This Deel withdrawal is no longer available in Deel and was removed from Stacks."
        return
      end

      super
    end

    def build_resource
      super.tap do |r|
        # Contributors#show action items pass ?ledger=<id> through to here so the
        # New Deel Withdrawal form binds to the same ledger as the selected tab.
        # Fall back to Sanctuary to keep older deep links working.
        selected = params[:ledger].present? && parent.ledgers.find_by(id: params[:ledger])
        r.ledger = selected || Ledger.find_or_create_for(enterprise: Enterprise.sanctuary, contributor: parent)
        r.date_submitted ||= Date.current
        if r.new_record? && r.deel_contract_id.blank?
          contracts = DeelContract.sorted_for_balance_withdrawal_select(
            parent.deel_person_id,
            deel_legal_entity_id: r.ledger.enterprise.deel_legal_entity_id,
          )
          r.deel_contract_id = contracts.first.deel_id if contracts.size == 1
        end
      end
    end

    def create
      submitted = params.require(:deel_invoice_adjustment).permit(
        :deel_contract_id,
        :amount,
        :description,
        :date_submitted,
        :allow_ledger_overdraw,
      )

      target_ledger =
        (params[:ledger].present? && parent.ledgers.find_by(id: params[:ledger])) ||
          Ledger.find_or_create_for(enterprise: Enterprise.sanctuary, contributor: parent)

      record = Contributors::SubmitDeelInvoiceAdjustment.call(
        contributor: parent,
        ledger: target_ledger,
        contract_id: submitted[:deel_contract_id],
        amount: submitted[:amount],
        description: submitted[:description],
        date_submitted: submitted[:date_submitted].presence || Date.current,
        skip_balance_validation: skip_balance_validation_for_request?(submitted),
      )

      redirect_to admin_contributor_deel_invoice_adjustment_path(parent, record),
        notice: "Deel withdrawal submitted and saved."
    rescue Contributors::SubmitDeelInvoiceAdjustment::Error => e
      flash.now[:alert] = e.message
      @deel_invoice_adjustment = build_resource
      @deel_invoice_adjustment.assign_attributes(submitted.to_h)
      render :new, status: :unprocessable_entity
    end
  end

  index download_links: false do
    column :date_submitted
    column :deel_contract_id
    column :amount
    column :deel_status
    column :description do |r|
      truncate(r.description.to_s, length: 80)
    end
    actions
  end

  form do |f|
    f.semantic_errors
    contracts = DeelContract.sorted_for_balance_withdrawal_select(
      f.object.contributor.deel_person_id,
      deel_legal_entity_id: f.object.ledger.enterprise.deel_legal_entity_id,
    )
    ledger_collection = Ledger.includes(:enterprise, contributor: :forecast_person).map do |l|
      ["#{l.enterprise.name} — #{l.contributor.forecast_person.email}", l.id]
    end
    f.inputs do
      f.input :ledger,
        as: :select,
        collection: ledger_collection,
        selected: f.object.ledger_id,
        input_html: { disabled: true }
      f.input :ledger_id, as: :hidden
      f.input :deel_contract_id,
        as: :select,
        collection: contracts.map { |dc| [dc.display_name_for_deel_invoice_select, dc.deel_id] },
        include_blank: "Choose…",
        required: true,
        label: "Deel contract"
      f.input :amount, as: :number, input_html: { step: 0.01, min: 0.01 }, label: "Amount (USD)"
      f.input :description, as: :text, input_html: { rows: 4, placeholder: "Work during March 2026" }
      f.input :date_submitted, as: :date_picker
      if deel_invoice_overdraw_checkbox_visible?
        f.input :allow_ledger_overdraw,
          as: :boolean,
          label: "Admin only: Allow overdrawn ledger balance",
          hint: "When checked, Stacks will not require this amount to fit within the contributor’s current settled ledger balance. Only users with the admin role see this option."
      end
    end
    f.actions
  end

  show do
    render partial: "show", locals: { resource: resource }
  end
end
