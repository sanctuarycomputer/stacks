ActiveAdmin.register PayCycle do
  belongs_to :enterprise
  menu false
  config.filters = false
  config.paginate = false
  actions :index, :show

  controller do
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
end
