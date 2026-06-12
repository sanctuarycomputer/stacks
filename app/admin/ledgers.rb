ActiveAdmin.register Ledger do
  menu false
  config.filters = false
  config.paginate = false
  # :index is needed so admin_ledgers_path exists — the breadcrumb on nested
  # resources (e.g. /admin/ledgers/:id/contributor_adjustments/new) links to
  # the parent's index. Without it, the breadcrumb link is missing.
  actions :index, :show
  permit_params

  member_action :migrate_to_qbo_bound, method: :post do
    unless resource.legacy?
      redirect_to admin_ledger_path(resource), alert: "Already QBO-bound."
      return
    end
    result = Ledgers::QboBoundMigrationCheck.call(resource)
    if result.ready?
      resource.update!(mode: :qbo_bound)
      redirect_to admin_ledger_path(resource), notice: "Migrated to QBO-bound."
    else
      redirect_to admin_ledger_path(resource),
        alert: "Cannot migrate: Δbalance #{number_to_currency(result.balance_delta)}, Δunsettled #{number_to_currency(result.unsettled_delta)}."
    end
  end

  show do
    attributes_table do
      row :id
      row :enterprise
      row :contributor
      row :mode
      row :payment_methods
    end

    if resource.legacy?
      panel "Migrate to QBO-bound" do
        result = Ledgers::QboBoundMigrationCheck.call(resource)
        div do
          para "Current (legacy):  balance #{number_to_currency(result.current_balance)}   unsettled #{number_to_currency(result.current_unsettled)}"
          para "Proposed (qbo_bound):  balance #{number_to_currency(result.proposed_balance)}   unsettled #{number_to_currency(result.proposed_unsettled)}"
          para "Δ balance #{number_to_currency(result.balance_delta)}, Δ unsettled #{number_to_currency(result.unsettled_delta)}"
        end
        if result.ready?
          div do
            para "Net-zero change — safe to migrate."
            button_to "Migrate to QBO-bound", migrate_to_qbo_bound_admin_ledger_path(resource), method: :post, data: { confirm: "Flip this ledger to qbo_bound?" }
          end
        else
          div do
            if result.blocking_bills.any?
              para "Open QBO bills blocking the migration:"
              ul do
                result.blocking_bills.first(20).each do |bb|
                  li do
                    text_node "#{bb.host.class.name} ##{bb.host.id} — #{number_to_currency(bb.amount.to_f)} — "
                    link_to "Pay in QBO ↗", bb.qbo_bill.qbo_url, target: "_blank", rel: "noopener"
                  end
                end
              end
            end
            if result.ignored_negative_cas.any?
              para "Negative CAs (audit-only after migration):"
              ul do
                result.ignored_negative_cas.first(10).each do |ca|
                  li "CA ##{ca.id} — #{number_to_currency(ca.amount.to_f)}"
                end
              end
            end
            para "Resolve the open bills in QBO, then refresh this page or click Re-check."
            button_to "Re-check", admin_ledger_path(resource), method: :get
          end
        end
      end
    end
  end
end
