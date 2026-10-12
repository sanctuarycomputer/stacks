ActiveAdmin.register MsoTrueup do
  config.filters = false
  config.paginate = false
  menu false
  # :show only. There is no index (the list of everyone's true-ups is the
  # snapshot, which is admin-only) and no new, edit or destroy:
  # Mso::MonthlyRun is the only thing that writes a true-up.
  #
  # AdminAuthorization lets an admin, or the executive whose ledger this is
  # on, read it. Only that executive may accept it; not even an admin can
  # accept for them.
  actions :show

  belongs_to :ledger

  action_item :toggle_acceptance, only: :show,
    if: proc { !resource.locked? && authorized?(:toggle_acceptance, resource) } do
    # The amount goes with the click: if a run has changed it since this page
    # was drawn, the acceptance is refused rather than landing on a figure
    # the person never saw.
    link_to (resource.accepted? ? "Unaccept" : "Accept"),
      toggle_acceptance_admin_ledger_mso_trueup_path(resource.ledger, resource, amount: resource.amount.to_s("F")),
      method: :post
  end

  action_item :remove_qbo_bill, only: :show,
    if: proc { current_admin_user.is_admin? && resource.locked? } do
    link_to "Remove QuickBooks bill",
      remove_qbo_bill_admin_ledger_mso_trueup_path(resource.ledger, resource),
      method: :post,
      data: { confirm: "Delete this true-up's bill in QuickBooks? Stacks checks QuickBooks first and refuses " \
                       "if the bill has any payment. The true-up will need accepting again, and the month " \
                       "must be run again before anything from it can be paid." }
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

    resource.toggle_acceptance!(expected_amount: params.require(:amount))
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
      notice: resource.accepted? ? "Accepted." : "Acceptance withdrawn."
  rescue MsoTrueup::Locked, MsoTrueup::AmountChanged => e
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource), alert: e.message
  rescue ActionController::ParameterMissing
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
      alert: "Open the true-up and accept it from there."
  end

  # The one way to unlock a true-up whose amount needs to change. Reads the
  # bill from QuickBooks, refuses if it has any payment, deletes it, clears
  # the acceptance and invalidates the snapshot (MsoTrueup#remove_qbo_bill!).
  member_action :remove_qbo_bill, method: :post do
    unless current_admin_user.is_admin?
      redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource), alert: "Only an admin can remove a bill."
      return
    end
    bill_id = resource.qbo_bill_id
    resource.remove_qbo_bill!

    # remove_qbo_bill! does nothing to the bill, and says nothing, when
    # Stacks holds no stored copy of it: the bill is still in QuickBooks and
    # this row still points at it. Never report that as a removal. (The
    # acceptance and the run have been withdrawn all the same, which fails
    # closed.)
    if resource.reload.locked?
      redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
        alert: "The QuickBooks bill was NOT removed. Stacks holds no stored copy of bill #{bill_id}, so it " \
               "could not check it for payments, and it is still in QuickBooks. The nightly refresh restores " \
               "the stored copy; try again after it has run. This true-up's acceptance was cleared and the " \
               "month's run marked invalid: run the month again once the bill is dealt with."
      return
    end

    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource),
      notice: "The QuickBooks bill was removed. Run the month again; this true-up will then need accepting again."
  rescue SyncsAsQboBill::PaidQboBillError => e
    redirect_to admin_ledger_mso_trueup_path(resource.ledger, resource), alert: e.message
  end

  show do
    render partial: "show", locals: { resource: resource }
  end
end
