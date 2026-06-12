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
    result = Ledgers::QboBoundMigrationCheck.call(resource)
    if result.ready?
      resource.update!(mode: :qbo_bound)
      redirect_to admin_ledger_path(resource), notice: "Migrated to QBO-bound."
    else
      redirect_to admin_ledger_path(resource),
        alert: "Cannot migrate: Δbalance #{result.balance_delta}, Δunsettled #{result.unsettled_delta}."
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
          para "Current (legacy):  balance $#{result.current_balance}   unsettled $#{result.current_unsettled}"
          para "Proposed (qbo_bound):  balance $#{result.proposed_balance}   unsettled $#{result.proposed_unsettled}"
          para "Δ balance #{result.balance_delta}, Δ unsettled #{result.unsettled_delta}"
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
                    text_node "#{bb.host.class.name} ##{bb.host.id} — $#{bb.amount.to_f.round(2)} — "
                    link_to "Pay in QBO ↗", bb.qbo_bill.qbo_url, target: "_blank", rel: "noopener"
                  end
                end
              end
            end
            if result.ignored_negative_cas.any?
              para "Negative CAs (audit-only after migration):"
              ul do
                result.ignored_negative_cas.first(10).each do |ca|
                  li "CA ##{ca.id} — $#{ca.amount.to_f.round(2)}"
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
