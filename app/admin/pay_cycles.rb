ActiveAdmin.register PayCycle do
  belongs_to :enterprise
  menu false
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :show, :destroy
  permit_params :starts_at, :ends_at

  controller do
    def new
      parent = Enterprise.find(params[:enterprise_id])
      default_range = parent.pay_cycle_default_range_for(Date.today)
      @pay_cycle = parent.pay_cycles.new(
        starts_at: default_range&.first,
        ends_at: default_range&.last,
      )
    end

    def create
      parent = Enterprise.find(params[:enterprise_id])
      @pay_cycle = parent.pay_cycles.new(
        permitted_params[:pay_cycle].merge(created_by: current_admin_user),
      )
      if @pay_cycle.save
        redirect_to admin_enterprise_pay_cycle_path(parent, @pay_cycle), notice: "Pay cycle created."
      else
        flash.now[:error] = @pay_cycle.errors.full_messages.join(", ")
        render :new
      end
    end

    helper_method :regen_confirm_message

    def regen_confirm_message(cycle)
      n = cycle.pay_stubs.where.not(accepted_at: nil).count
      return nil if n.zero?
      "Regen may reset acceptance on up to #{n} already-accepted stub(s) if amounts change. Continue?"
    end
  end

  action_item :regenerate, only: :show do
    link_to "Regenerate from Forecast",
      regenerate_admin_enterprise_pay_cycle_path(resource.enterprise, resource),
      method: :post,
      data: { confirm: regen_confirm_message(resource) }
  end

  member_action :regenerate, method: :post do
    PayCycles::GenerateStubs.call(resource)
    redirect_to admin_enterprise_pay_cycle_path(resource.enterprise, resource), notice: "Stubs regenerated."
  rescue PayCycles::GenerateStubs::MissingRateError, PayCycles::GenerateStubs::AcceptedStubMissingHoursError => e
    redirect_to admin_enterprise_pay_cycle_path(resource.enterprise, resource), alert: e.message
  end

  show do
    render partial: "show", locals: { resource: resource }
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :starts_at, as: :date_picker
      f.input :ends_at, as: :date_picker
    end
    f.actions
  end
end
