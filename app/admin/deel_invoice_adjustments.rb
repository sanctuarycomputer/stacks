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
      return if manual_deel_invoice_submission_allowed?(parent)

      redirect_to admin_contributor_path(parent), alert: "That action is not available."
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
        r.contributor = parent
        r.date_submitted ||= Date.current
        if r.new_record? && r.deel_contract_id.blank?
          contracts = DeelContract.sorted_for_balance_withdrawal_select(parent.deel_person_id)
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

      record = Contributors::SubmitDeelInvoiceAdjustment.call(
        contributor: parent,
        contract_id: submitted[:deel_contract_id],
        amount: submitted[:amount],
        description: submitted[:description],
        date_submitted: submitted[:date_submitted].presence || Date.current,
        bypass_team_allowlist: current_admin_user.is_admin?,
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
    contracts = DeelContract.sorted_for_balance_withdrawal_select(f.object.contributor.deel_person_id)
    f.inputs do
      f.input :contributor, input_html: { disabled: true }
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
