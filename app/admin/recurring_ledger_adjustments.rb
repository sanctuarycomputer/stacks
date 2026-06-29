ActiveAdmin.register RecurringLedgerAdjustment do
  menu label: "Recurring Adjustments", parent: "Team"
  config.filters = false
  actions :index, :new, :create, :edit, :update, :destroy

  permit_params :ledger_id, :amount, :description, :cadence, :next_due_on, :paused_at

  controller do
    def scoped_collection
      super.includes(ledger: [:enterprise, { contributor: :forecast_person }])
    end
  end

  action_item :materialize_now, only: :edit do
    link_to "Materialize Now",
      materialize_now_admin_recurring_ledger_adjustment_path(resource),
      method: :post,
      data: { confirm: "Create a ContributorAdjustment for #{resource.next_due_on} immediately?" }
  end

  member_action :materialize_now, method: :post do
    if resource.paused?
      redirect_to edit_admin_recurring_ledger_adjustment_path(resource), alert: "Row is paused."
      return
    end
    adj = resource.materialize!
    if adj.nil?
      # materialize! returns nil when it auto-pauses (negative CA on a
      # qbo_bound ledger would land as audit-only). resource is now paused;
      # reload + alert.
      resource.reload
      redirect_to edit_admin_recurring_ledger_adjustment_path(resource),
        alert: "Auto-paused — negative recurring on a QBO-bound ledger would land as audit-only and never deduct. Resume only after fixing the underlying setup."
    else
      redirect_to admin_ledger_contributor_adjustment_path(adj.ledger, adj),
        notice: "Created ContributorAdjustment ##{adj.id}."
    end
  rescue => e
    redirect_to edit_admin_recurring_ledger_adjustment_path(resource), alert: e.message
  end

  member_action :toggle_pause, method: :post do
    resource.update!(paused_at: resource.paused? ? nil : Time.current)
    redirect_to edit_admin_recurring_ledger_adjustment_path(resource),
      notice: resource.paused? ? "Paused." : "Resumed."
  end

  action_item :toggle_pause, only: :edit do
    label = resource.paused? ? "Resume" : "Pause"
    link_to label, toggle_pause_admin_recurring_ledger_adjustment_path(resource), method: :post
  end

  index download_links: false do
    column :contributor do |r|
      link_to r.ledger.contributor.forecast_person&.email || "Contributor ##{r.ledger.contributor_id}",
        admin_contributor_path(r.ledger.contributor)
    end
    column :enterprise do |r|
      r.ledger.enterprise.name
    end
    column :amount do |r|
      number_to_currency(r.amount)
    end
    column :description
    column :cadence
    column :next_due_on
    column :last_materialized_on
    column :status do |r|
      r.paused? ? status_tag("Paused") : status_tag("Active")
    end
    actions
  end

  form do |f|
    f.semantic_errors
    f.inputs do
      f.input :ledger,
        as: :select,
        collection: Ledger.includes(:enterprise, contributor: :forecast_person).map { |l|
          ["#{l.contributor.forecast_person&.email || "Contributor ##{l.contributor_id}"} — #{l.enterprise.name}", l.id]
        },
        prompt: "Choose a ledger…"
      f.input :amount, hint: "Use a negative number to deduct from the contributor's balance."
      f.input :description
      f.input :cadence,
        as: :select,
        collection: RecurringLedgerAdjustment::CADENCES,
        include_blank: false
      f.input :next_due_on, as: :datepicker, hint: "First effective_on date. The cron advances this column after each materialization."
    end
    f.actions
  end
end
