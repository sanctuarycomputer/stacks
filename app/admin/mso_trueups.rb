ActiveAdmin.register MsoTrueup do
  config.filters = false
  config.paginate = false
  menu false
  # :show only. The list of a month's true-ups is its monthly report, and
  # there is no new, edit or destroy: PeriodicReport#sync_mso_trueups! is the
  # only thing that writes a true-up.
  #
  # Only the executive it belongs to may accept it; not even an admin can
  # accept for them (AdminAuthorization).
  actions :show

  belongs_to :ledger

  action_item :toggle_acceptance, only: :show,
    if: proc { !resource.locked? && authorized?(:toggle_acceptance, resource) } do
    link_to (resource.accepted? ? "Unaccept" : "Accept"),
      toggle_acceptance_admin_ledger_mso_trueup_path(resource.ledger, resource),
      method: :post
  end

  member_action :toggle_acceptance, method: :post do
    # `resource` has already been authorized as :toggle_acceptance, which
    # AdminAuthorization grants to the owner alone. Checked again here.
    owner = resource.contributor.forecast_person&.admin_user
    unless owner.present? && owner == current_admin_user
      redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
        alert: "Only the person a true-up belongs to can accept it."
      return
    end

    resource.toggle_acceptance!
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
      notice: resource.accepted? ? "Accepted." : "Acceptance withdrawn."
  rescue MsoTrueup::Locked => e
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource), alert: e.message
  end

  show do
    render partial: "show", locals: { resource: resource }
  end
end
