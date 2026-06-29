ActiveAdmin.register Ledger do
  menu false
  config.filters = false
  config.paginate = false
  # :index is needed so admin_ledgers_path exists — the breadcrumb on nested
  # resources (e.g. /admin/ledgers/:id/contributor_adjustments/new) links to
  # the parent's index. Without it, the breadcrumb link is missing.
  actions :index, :show
  permit_params

  member_action :refresh_qbo_vendor, method: :post do
    unless current_admin_user.is_admin?
      redirect_to admin_ledger_path(resource), alert: "Admins only."
      return
    end
    qa = resource.enterprise&.qbo_account
    if qa.nil?
      redirect_to admin_ledger_path(resource), alert: "No QBO account connected for #{resource.enterprise&.name}."
      return
    end
    qa.sync_all_vendors!
    redirect_to admin_ledger_path(resource), notice: "Refreshed QBO vendor data for #{resource.enterprise.name}."
  rescue => e
    Rails.logger.error("[refresh_qbo_vendor] ledger=#{resource.id}: #{e.class}: #{e.message}")
    redirect_to admin_ledger_path(resource), alert: "Refresh failed: #{e.message}"
  end

  member_action :migrate_to_qbo_bound, method: :post do
    unless current_admin_user.is_admin?
      redirect_to admin_ledger_path(resource), alert: "Admins only."
      return
    end
    unless resource.legacy?
      redirect_to admin_ledger_path(resource), alert: "Already QBO-bound."
      return
    end
    result = Ledgers::QboBoundMigrationCheck.call(resource)
    if result.ready?
      begin
        resource.update!(mode: :qbo_bound)
        redirect_to admin_ledger_path(resource), notice: "Migrated to QBO-bound."
      rescue ActiveRecord::RecordInvalid => e
        # Belt-and-suspenders: surface validation failures as a clean flash
        # instead of a 500. No specific validation currently blocks this path,
        # but future cross-field invariants might.
        redirect_to admin_ledger_path(resource), alert: "Cannot migrate: #{e.record.errors.full_messages.join(", ")}."
      end
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
        tol = Ledgers::QboBoundMigrationCheck::TOLERANCE
        open_bills_total = result.open_qbo_bills.sum { |b| b.amount.to_f }.round(2)
        neg_ca_total = result.removed_neg_cas.sum { |ca| ca.amount.to_f.abs }.round(2)
        unsynced_total = result.unsynced_total.to_f.round(2)

        # ====================================================================
        # ACCOUNTANT-FACING ACTION PANEL — leads with WHAT TO DO, in plain
        # English. Engineer-facing diagnostics live below.
        # ====================================================================
        div do
          h4 "What needs to happen"

          if result.qbo_match?
            para style: "padding: 0.75em; background: #ddf4dd; border-left: 3px solid #2a8d2a;" do
              strong("Ready to migrate. ")
              text_node "Stacks and QBO agree this contributor is owed #{number_to_currency(result.stacks_open_total)}. Click the button below to flip the ledger over."
            end

          elsif result.qbo_vendor_missing?
            para style: "padding: 0.75em; background: #fde2e2; border-left: 3px solid #c00;" do
              strong("Set up a QBO vendor for this contributor on #{resource.enterprise.name}. ")
              text_node "Without a vendor mapping in QBO we can't compare Stacks's balance against QBO's vendor AP. Go to the contributor's admin page → 'QBO Vendor Mappings' → add the right vendor on #{resource.enterprise.name}, then return here and re-check."
            end

          elsif result.qbo_diff.nil?
            para style: "padding: 0.75em; background: #fde2e2; border-left: 3px solid #c00;" do
              strong("QBO vendor balance is missing or unreadable. ")
              text_node "Stacks couldn't parse data['balance'] on the QBO vendor record. Click 'Refresh QBO vendor data' below — if the problem persists, open the vendor in QBO and confirm the record is healthy."
            end

          else
            # We have a numeric diff. Figure out the most actionable explanation.
            #
            # Pattern 1: Open QBO bills explain the diff, and Stacks-side
            #   negative CAs roughly match those bills. This is the "contributor
            #   was paid via Deel (or otherwise), bills still open in QBO" case.
            # Pattern 2: Open QBO bills explain the diff, no matching CAs.
            #   Bills are genuinely outstanding (need paying) OR vendor cache
            #   is stale.
            # Pattern 3: Unsynced Stacks rows explain the diff. Push them.
            # Pattern 4: True drift — Stacks shows more owed than QBO with no
            #   open bills to explain it. Vendor credit / Expense-to-AP / etc.
            # Pattern 5: QBO shows more than Stacks. Unknown bill on the QBO side.

            open_bills_match_diff   = result.qbo_diff > 0 && open_bills_total > 0 &&
                                      (result.qbo_diff - open_bills_total).abs < tol
            neg_cas_match_bills     = open_bills_total > 0 && neg_ca_total > 0 &&
                                      (open_bills_total - neg_ca_total).abs < tol
            unsynced_explains_all   = result.qbo_diff > 0 && unsynced_total > 0 &&
                                      (result.qbo_diff - unsynced_total).abs < tol
            unsynced_explains_some  = result.qbo_diff > 0 && unsynced_total > 0 &&
                                      !unsynced_explains_all

            who_link = link_to(resource.contributor.forecast_person&.email || "Contributor ##{resource.contributor_id}",
                               admin_contributor_path(resource.contributor))

            if open_bills_match_diff && neg_cas_match_bills
              # Pattern 1 — Deel-reconciliation pattern
              para style: "padding: 0.75em; background: #fff8db; border-left: 3px solid #c69b00;" do
                strong("Action: mark #{pluralize(result.open_qbo_bills.size, 'open QBO bill')} as Paid in QuickBooks. ")
                text_node "Stacks shows #{number_to_currency(open_bills_total)} of work that was already settled outside QuickBooks — there #{result.removed_neg_cas.size == 1 ? 'is' : 'are'} #{pluralize(result.removed_neg_cas.size, 'matching deduction')} on the Stacks side (listed below) totaling #{number_to_currency(neg_ca_total)}, which typically means the contributor was paid via Deel."
              end
              div style: "padding: 0.5em 0.75em; background: #fffdf3; border-left: 3px solid #c69b00; margin-top: -0.4em;" do
                para strong("Step-by-step:")
                ol style: "margin-top: 0;" do
                  li "In QuickBooks, open each of the bills listed below and match it against the Deel bank withdrawal (or whatever transfer paid the contributor)."
                  li "Once all #{result.open_qbo_bills.size} #{result.open_qbo_bills.size == 1 ? 'bill is' : 'bills are'} marked Paid, come back to this page and click 'Re-check'."
                  li "The ledger will then be ready to migrate."
                end
              end

            elsif open_bills_match_diff
              # Pattern 2 — open bills explain but no offset
              para style: "padding: 0.75em; background: #fff8db; border-left: 3px solid #c69b00;" do
                strong("Action: either pay #{pluralize(result.open_qbo_bills.size, 'open QBO bill')} (#{number_to_currency(open_bills_total)}), or refresh the cached vendor balance. ")
                text_node "The diff is exactly the total of bills currently open in QuickBooks against this vendor. Either Finance hasn't paid them yet (pay them in QBO or match a bank transaction), or the cached QBO vendor balance on Stacks is stale and the bills are already paid (use 'Refresh QBO vendor data' below)."
              end

            elsif unsynced_explains_all
              para style: "padding: 0.75em; background: #fff8db; border-left: 3px solid #c69b00;" do
                strong("Action: sync #{pluralize(result.unsynced_hosts.size, 'Stacks row')} to QBO. ")
                text_node "#{result.unsynced_hosts.size} payable row(s) totaling #{number_to_currency(unsynced_total)} haven't been pushed to QBO yet. Use the per-row 'Sync to QBO' actions on the Money page, or run the daily sync — then re-check here."
              end

            elsif unsynced_explains_some
              remaining = (result.qbo_diff - unsynced_total).round(2)
              para style: "padding: 0.75em; background: #fff8db; border-left: 3px solid #c69b00;" do
                if remaining > 0
                  strong("Partially explained by unsynced rows. ")
                  text_node "#{pluralize(result.unsynced_hosts.size, 'unsynced row')} accounts for #{number_to_currency(unsynced_total)} of the #{number_to_currency(result.qbo_diff)} diff. The remaining #{number_to_currency(remaining)} is unexplained — likely a vendor credit or Expense-to-AP entry in QBO that Stacks can't see. Sync the rows first, then investigate the remainder."
                else
                  strong("Unsynced rows over-explain the diff. ")
                  text_node "#{pluralize(result.unsynced_hosts.size, 'unsynced row')} totals #{number_to_currency(unsynced_total)}, but the QBO diff is only #{number_to_currency(result.qbo_diff)}. Likely one of the unsynced rows is a duplicate or shouldn't exist — review the list below before syncing."
                end
              end

            elsif result.qbo_diff > 0
              # Pattern 4 — true drift, Stacks > QBO, nothing explains it
              para style: "padding: 0.75em; background: #fde2e2; border-left: 3px solid #c00;" do
                strong("Stacks shows #{number_to_currency(result.qbo_diff)} more owed than QuickBooks. ")
                text_node "There are no open QBO bills or unsynced Stacks rows that could account for the gap. Most likely there's a vendor credit or Expense-to-AP entry in QBO that Stacks doesn't know about (it reduces the vendor's AP). Look up "
                text_node who_link
                text_node " in QuickBooks → review the vendor's AP history for entries Stacks isn't tracking."
              end

            else
              # Pattern 5 — QBO > Stacks
              para style: "padding: 0.75em; background: #fde2e2; border-left: 3px solid #c00;" do
                strong("QuickBooks shows #{number_to_currency(result.qbo_diff.abs)} more owed than Stacks. ")
                text_node "Most likely there's a bill in QBO that Stacks doesn't know about — created manually in QBO, or attached to a host whose qbo_bill_id was nulled. Look up "
                text_node who_link
                text_node " in QuickBooks → find the extra bill(s) → either delete them in QBO if they're spurious, or create a matching Stacks record."
              end
            end

            # Always offer the vendor-refresh button below the action.
            div style: "margin-top: 0.75em;" do
              button_to "Refresh QBO vendor data",
                        refresh_qbo_vendor_admin_ledger_path(resource),
                        method: :post,
                        data: { confirm: "Fetch all vendors for #{resource.enterprise.name} from QBO? Takes a few seconds." }
              para style: "font-size: 0.85em; opacity: 0.7;" do
                text_node "Pulls the latest vendor AP balance from QBO. Use this after marking bills Paid or if you suspect Stacks's cached value is stale."
              end
            end
          end
        end

        # ====================================================================
        # NUMBERS — compact summary for the engineer/auditor
        # ====================================================================
        unless result.qbo_vendor_missing?
          div style: "margin-top: 1em; padding-top: 0.5em; border-top: 1px solid #ddd; font-size: 0.9em; opacity: 0.85;" do
            h4 "Numbers"
            para "Stacks (proposed qbo_bound) open total: #{number_to_currency(result.stacks_open_total)} = balance #{number_to_currency(result.proposed_balance)} + unsettled #{number_to_currency(result.proposed_unsettled)}"
            para "QBO vendor AP balance: #{number_to_currency(result.qbo_vendor_balance)}"
            para "Diff (Stacks − QBO): #{number_to_currency(result.qbo_diff)}" unless result.qbo_match? || result.qbo_diff.nil?
          end
        end

        if result.ready?
          div style: "margin-top: 1em;" do
            button_to "Migrate to QBO-bound", migrate_to_qbo_bound_admin_ledger_path(resource), method: :post, data: { confirm: "Flip this ledger to qbo_bound? Stacks total and QBO balance match — this is safe." }
          end
        else
          # Open QBO bills FIRST — these are what the accountant acts on. Each
          # has a deep link into QBO.
          if result.open_qbo_bills.any?
            div style: "margin-top: 1em;" do
              h4 "Open QBO bills for this contributor — total #{number_to_currency(open_bills_total)}"
              para "Each link opens the bill in QuickBooks. Mark them Paid (or match against a bank withdrawal) to clear them from the AP."
              ul do
                result.open_qbo_bills.first(20).each do |b|
                  li do
                    text_node "#{b.host.class.name} ##{b.host.id} — #{number_to_currency(b.amount.to_f)} — "
                    link_to "Open bill in QuickBooks ↗", b.qbo_bill.qbo_url, target: "_blank", rel: "noopener"
                  end
                end
                li "… and #{result.open_qbo_bills.size - 20} more" if result.open_qbo_bills.size > 20
              end
            end
          end

          # Stacks-side rows that haven't reached QBO yet — operator action.
          if result.unsynced_hosts.any?
            div style: "margin-top: 1em;" do
              h4 "Stacks rows not yet synced to QBO — total #{number_to_currency(result.unsynced_total)}"
              para "These payable rows in Stacks haven't been pushed to QBO as bills yet. They make Stacks's total look bigger than QuickBooks's."
              ul do
                result.unsynced_hosts.first(20).each do |u|
                  li do
                    text_node "#{u.host.class.name} ##{u.host.id} — #{number_to_currency(u.amount.to_f)}"
                    if u.host.respond_to?(:description) && u.host.description.present?
                      text_node " — #{u.host.description.to_s.truncate(70)}"
                    end
                  end
                end
                li "… and #{result.unsynced_hosts.size - 20} more" if result.unsynced_hosts.size > 20
              end
            end
          end

          # Stacks bookkeeping that doesn't count under qbo_bound — usually
          # the offset that matches the open QBO bills above.
          if result.removed_neg_cas.any? || result.removed_dias.any?
            div style: "margin-top: 1em;" do
              h4 "Stacks-side payment records (don't count toward QBO-bound balance)"
              para "These are Stacks-side bookkeeping entries that mark money as already paid. Under QBO-bound, QuickBooks's bill status is the source of truth, so these don't affect the balance — they're shown here so you can match them to the QBO bills above."

              if result.removed_neg_cas.any?
                neg_ca_sum = result.removed_neg_cas.sum { |ca| ca.amount.to_f }.round(2)
                para strong("Negative adjustments: #{number_to_currency(neg_ca_sum)} total")
                ul do
                  result.removed_neg_cas.first(15).each do |ca|
                    li "CA ##{ca.id} — #{number_to_currency(ca.amount.to_f)}    #{ca.description.to_s.truncate(70)}"
                  end
                  li "… and #{result.removed_neg_cas.size - 15} more" if result.removed_neg_cas.size > 15
                end
              end

              if result.removed_dias.any?
                dia_sum = result.removed_dias.sum { |d| d.amount.to_f }.round(2)
                para strong("Deel invoice adjustments: #{number_to_currency(dia_sum)} total")
                ul do
                  result.removed_dias.first(15).each do |d|
                    li "DIA ##{d.id} — #{number_to_currency(d.amount.to_f)}    #{d.description.to_s.truncate(70)}"
                  end
                  li "… and #{result.removed_dias.size - 15} more" if result.removed_dias.size > 15
                end
              end
            end
          end

          # Bills marked Paid in QBO that no longer count.
          if result.dropped_paid_hosts.any?
            paid_sum = result.dropped_paid_hosts.sum { |b| b.amount.to_f }.round(2)
            div style: "margin-top: 1em;" do
              h4 "QBO bills already Paid — total #{number_to_currency(paid_sum)}"
              para "Listed for reference. These are settled in QuickBooks and don't affect the migration."
              ul do
                result.dropped_paid_hosts.first(15).each do |b|
                  li do
                    text_node "#{b.host.class.name} ##{b.host.id} — #{number_to_currency(b.amount.to_f)} — "
                    link_to "View in QuickBooks ↗", b.qbo_bill.qbo_url, target: "_blank", rel: "noopener"
                  end
                end
                li "… and #{result.dropped_paid_hosts.size - 15} more" if result.dropped_paid_hosts.size > 15
              end
            end
          end

          div style: "margin-top: 1em;" do
            button_to "Re-check", admin_ledger_path(resource), method: :get
          end

          # Engineer-facing diagnostic — pushed to the bottom.
          div style: "margin-top: 1em; padding-top: 0.5em; border-top: 1px solid #ddd; font-size: 0.85em; opacity: 0.7;" do
            h4 "Technical details"
            para "Current (legacy):    balance #{number_to_currency(result.current_balance)}   unsettled #{number_to_currency(result.current_unsettled)}"
            para "Proposed (qbo_bound):  balance #{number_to_currency(result.proposed_balance)}   unsettled #{number_to_currency(result.proposed_unsettled)}"
            para "Δ balance #{number_to_currency(result.balance_delta)}, Δ unsettled #{number_to_currency(result.unsettled_delta)}"
          end
        end
      end
    end
  end
end
