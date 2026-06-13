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
    elsif result.qbo_vendor_missing?
      redirect_to admin_ledger_path(resource),
        alert: "Cannot migrate: no QBO vendor mapping for this contributor on #{resource.enterprise.name}."
    else
      redirect_to admin_ledger_path(resource),
        alert: "Cannot migrate: Stacks total #{helpers.number_to_currency(result.stacks_open_total)} does not match QBO vendor balance #{helpers.number_to_currency(result.qbo_vendor_balance)} (diff #{helpers.number_to_currency(result.qbo_diff)})."
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
          h4 "QBO match check"
          if result.qbo_vendor_missing?
            para strong("No QBO vendor mapping for this contributor on #{resource.enterprise.name}.")
            para "Set up the vendor mapping before migrating — we can't compare against QBO without it."
          else
            para "Stacks (proposed qbo_bound) open total: #{number_to_currency(result.stacks_open_total)} = balance #{number_to_currency(result.proposed_balance)} + unsettled #{number_to_currency(result.proposed_unsettled)}"
            para "QBO vendor AP balance:                 #{number_to_currency(result.qbo_vendor_balance)}"
            if result.qbo_match?
              para strong("Match. Safe to migrate — qbo_bound will mirror QBO one-to-one.")
            else
              para strong("Does NOT match. Diff: #{number_to_currency(result.qbo_diff)} (Stacks − QBO).")
              if result.qbo_diff > 0
                para "Stacks shows MORE owed than QBO. Likely cause: an Expense-to-AP or vendor credit in QBO that reduces AP, which Stacks can't see. Reconcile in QBO first (add the missing offset in Stacks, or verify the QBO entry is correct)."
              else
                para "QBO shows MORE owed than Stacks. Likely cause: an open Bill in QBO that Stacks doesn't know about (host without qbo_bill_id, or a Bill created outside Stacks). Sync the missing Bill or verify the QBO entry."
              end
            end
          end
        end

        if result.ready?
          div do
            button_to "Migrate to QBO-bound", migrate_to_qbo_bound_admin_ledger_path(resource), method: :post, data: { confirm: "Flip this ledger to qbo_bound? Stacks total and QBO balance match — this is safe." }
          end
        else
          div do
            h4 "Diagnostic — legacy vs qbo_bound (independent of QBO check)"
            para "Current (legacy):    balance #{number_to_currency(result.current_balance)}   unsettled #{number_to_currency(result.current_unsettled)}"
            para "Proposed (qbo_bound):  balance #{number_to_currency(result.proposed_balance)}   unsettled #{number_to_currency(result.proposed_unsettled)}"
            para "Δ balance #{number_to_currency(result.balance_delta)}, Δ unsettled #{number_to_currency(result.unsettled_delta)}"
          end

          neg_ca_sum = result.removed_neg_cas.sum { |ca| ca.amount.to_f }.round(2)
          dia_sum    = result.removed_dias.sum    { |d|  d.amount.to_f }.round(2)
          paid_sum   = result.dropped_paid_hosts.sum { |b| b.amount.to_f }.round(2)

          if result.removed_neg_cas.any? || result.removed_dias.any? || result.dropped_paid_hosts.any?
            div do
              h4 "Items behaving differently under qbo_bound"

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
          end

          if result.open_qbo_bills.any?
            div do
              h4 "Open QBO bills on this ledger"
              para "Marking one Paid in QBO turns it into a dropped paid host and reduces Stacks open total by its amount."
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
          end

          div do
            button_to "Re-check", admin_ledger_path(resource), method: :get
          end
        end
      end
    end
  end
end
