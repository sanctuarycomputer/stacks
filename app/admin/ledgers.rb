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
        alert: "Cannot migrate: Δbalance #{helpers.number_to_currency(result.balance_delta)}, Δunsettled #{helpers.number_to_currency(result.unsettled_delta)}."
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
          para "Current (legacy):    balance #{number_to_currency(result.current_balance)}   unsettled #{number_to_currency(result.current_unsettled)}"
          para "Proposed (qbo_bound):  balance #{number_to_currency(result.proposed_balance)}   unsettled #{number_to_currency(result.proposed_unsettled)}"
          para "Δ balance #{number_to_currency(result.balance_delta)}, Δ unsettled #{number_to_currency(result.unsettled_delta)}"
        end

        if result.ready?
          div do
            para "Net-zero change — safe to migrate."
            button_to "Migrate to QBO-bound", migrate_to_qbo_bound_admin_ledger_path(resource), method: :post, data: { confirm: "Flip this ledger to qbo_bound?" }
          end
        else
          neg_ca_sum = result.removed_neg_cas.sum { |ca| ca.amount.to_f }.round(2)
          dia_sum    = result.removed_dias.sum    { |d|  d.amount.to_f }.round(2)
          paid_sum   = result.dropped_paid_hosts.sum { |b| b.amount.to_f }.round(2)

          div do
            h4 "What's driving the Δ"
            para "Under qbo_bound these items behave differently. The net (sum of audit-only deductions removed, minus paid hosts dropping out) is Δbalance."

            if result.removed_neg_cas.any?
              para strong("Negative CAs ignored as audit-only: #{number_to_currency(neg_ca_sum)} (+#{number_to_currency(neg_ca_sum.abs)} to Δ)")
              ul do
                result.removed_neg_cas.first(15).each do |ca|
                  li "CA ##{ca.id} — #{number_to_currency(ca.amount.to_f)}    #{ca.description.to_s.truncate(70)}"
                end
                li "… and #{result.removed_neg_cas.size - 15} more" if result.removed_neg_cas.size > 15
              end
            end

            if result.removed_dias.any?
              para strong("DIAs ignored as audit-only: #{number_to_currency(dia_sum)} (+#{number_to_currency(dia_sum.abs)} to Δ)")
              ul do
                result.removed_dias.first(15).each do |d|
                  li "DIA ##{d.id} — #{number_to_currency(d.amount.to_f)}    #{d.description.to_s.truncate(70)}"
                end
                li "… and #{result.removed_dias.size - 15} more" if result.removed_dias.size > 15
              end
            end

            if result.dropped_paid_hosts.any?
              para strong("Paid QBO bills dropping out: #{number_to_currency(paid_sum)} (−#{number_to_currency(paid_sum.abs)} to Δ)")
              ul do
                result.dropped_paid_hosts.first(15).each do |b|
                  li do
                    text_node "#{b.host.class.name} ##{b.host.id} — #{number_to_currency(b.amount.to_f)} — "
                    link_to "View in QBO ↗", b.qbo_bill.qbo_url, target: "_blank", rel: "noopener"
                  end
                end
                li "… and #{result.dropped_paid_hosts.size - 15} more" if result.dropped_paid_hosts.size > 15
              end
            end
          end

          if result.balance_delta > 0 && result.open_qbo_bills.any?
            div do
              h4 "Remedy options"
              para "Δ is positive, so qbo_bound would show MORE balance than legacy. Marking any of these open QBO bills as Paid in QBO will drop the corresponding host from qbo_bound balance, reducing Δ by its amount."
              ul do
                result.open_qbo_bills.first(20).each do |b|
                  li do
                    text_node "#{b.host.class.name} ##{b.host.id} — #{number_to_currency(b.amount.to_f)} — "
                    link_to "Pay in QBO ↗", b.qbo_bill.qbo_url, target: "_blank", rel: "noopener"
                  end
                end
                li "… and #{result.open_qbo_bills.size - 20} more" if result.open_qbo_bills.size > 20
              end
            end
          elsif result.balance_delta < 0
            div do
              h4 "Note"
              para "Δ is negative, so qbo_bound would show LESS balance than legacy. There are paid QBO bills here that aren't matched by audit-only deductions — either accept the lower balance and migrate, or add a corrective adjustment in legacy first."
            end
          end

          div do
            button_to "Re-check", admin_ledger_path(resource), method: :get
          end
        end
      end
    end
  end
end
