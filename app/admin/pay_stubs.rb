ActiveAdmin.register PayStub do
  belongs_to :pay_cycle
  menu false
  config.filters = false
  config.paginate = false
  actions :show

  action_item :toggle_acceptance, only: :show, if: proc {
    current_admin_user.is_admin? || current_admin_user.forecast_person == resource.contributor.forecast_person
  } do
    label = resource.accepted? ? "Unaccept" : "Accept"
    link_to label,
      toggle_acceptance_admin_pay_cycle_pay_stub_path(resource.pay_cycle, resource),
      method: :post
  end

  member_action :toggle_acceptance, method: :post do
    unless current_admin_user.is_admin? || current_admin_user.forecast_person == resource.contributor.forecast_person
      redirect_to admin_pay_cycle_pay_stub_path(resource.pay_cycle, resource), alert: "You are not authorized to do that."
      return
    end
    resource.toggle_acceptance!(by: current_admin_user)
    redirect_to admin_pay_cycle_pay_stub_path(resource.pay_cycle, resource), notice: "Updated."
  rescue RuntimeError => e
    redirect_to admin_pay_cycle_pay_stub_path(resource.pay_cycle, resource), alert: e.message
  end

  show do
    render partial: "show", locals: { resource: resource }
  end
end
