ActiveAdmin.register PayCycle do
  belongs_to :enterprise
  menu false
  config.filters = false
  config.paginate = false
  actions :index, :show

  controller do
    helper_method :regen_confirm_message

    before_action :require_admin_or_enterprise_admin!, only: [:show]

    def regen_confirm_message(cycle)
      n = cycle.pay_stubs.where.not(accepted_at: nil).count
      return nil if n.zero?
      "Regen may reset acceptance on up to #{n} already-accepted stub(s) if amounts change. Continue?"
    end

    private

    def require_admin_or_enterprise_admin!
      return if current_admin_user.is_admin?
      return if current_admin_user.admin_of?(resource.enterprise)
      redirect_to admin_root_path, alert: "You are not authorized to view this pay cycle."
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

  # Cycle-level approval (distinct from per-stub acceptance). Only enterprise
  # admins for this cycle's enterprise — or global super-admins — can flip it.
  action_item :toggle_approval, only: :show, if: proc { current_admin_user.admin_of?(resource.enterprise) } do
    label = resource.approved? ? "Unapprove cycle" : "Approve cycle"
    link_to label,
      toggle_approval_admin_enterprise_pay_cycle_path(resource.enterprise, resource),
      method: :post
  end

  member_action :toggle_approval, method: :post do
    resource.toggle_approval!(by: current_admin_user)
    redirect_to admin_enterprise_pay_cycle_path(resource.enterprise, resource),
      notice: resource.approved? ? "Cycle approved." : "Cycle un-approved."
  rescue PayCycle::NotAuthorizedToApprove => e
    redirect_to admin_enterprise_pay_cycle_path(resource.enterprise, resource), alert: e.message
  end

  show do
    render partial: "show", locals: { resource: resource }
  end
end
