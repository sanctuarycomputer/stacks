# The record of each run of a month's MSO compensation: fee income, the cap,
# the benchmark and every executive's line. ADMINS ONLY, for every action;
# AdminAuthorization enforces it above the blanket lead grant, and the menu
# item is hidden from everyone else because they cannot :read the class.
ActiveAdmin.register MsoSnapshot do
  menu label: "MSO Compensation", parent: "Money"
  config.filters = false
  config.sort_order = "created_at_desc"
  # Read-only. A snapshot is written by Mso::MonthlyRun and never edited.
  actions :index, :show

  controller do
    def scoped_collection
      super.includes(:invoice_pass)
    end
  end

  index download_links: false, title: "MSO Compensation" do
    column(:month) { |snapshot| snapshot.invoice_pass.invoice_month }
    column(:status) do |snapshot|
      if !snapshot.current? then "Superseded"
      elsif snapshot.invalidated? then "INVALID — run again"
      else "Current"
      end
    end
    column(:fee_income) { |snapshot| number_to_currency(snapshot.fee_income) }
    column(:cap) { |snapshot| number_to_currency(snapshot.cap) }
    column(:benchmark) { |snapshot| number_to_currency(BigDecimal(snapshot.benchmark_average)) }
    column(:total_true_up) { |snapshot| number_to_currency(snapshot.total_trueup) }
    column(:fee_collected) { |snapshot| snapshot.fee_collected? ? "Yes" : "No" }
    column(:warnings) do |snapshot|
      [
        ("over the cap" if snapshot.over_cap?),
        ("#{snapshot.drift.size} billed row(s) differ" if snapshot.drift.any?),
        ("#{snapshot.income_drift_lines.size} true-up(s) have moved since the run" if snapshot.income_drift_lines.any?),
        ("can no longer be computed" if snapshot.income_drift_refusal),
        ("unfinished at the run" if snapshot.run_warnings?),
      ].compact.join("; ")
    end
    column :created_at
    actions
  end

  action_item :check_collection, only: :show, if: proc { resource.current? && !resource.invalidated? } do
    link_to "Check collection", check_collection_admin_mso_snapshot_path(resource), method: :post,
      data: { confirm: "Read this month's management fee invoices from QuickBooks and record whether the " \
                       "fee has been paid?" }
  end

  # One QuickBooks READ per fee invoice. The answer is stamped on the
  # snapshot; MsoTrueup#payable? reads the stamp and never QuickBooks.
  member_action :check_collection, method: :post do
    unless current_admin_user.is_admin?
      redirect_to admin_root_path, alert: "Only an admin can check collection."
      return
    end

    begin
      collected = resource.check_collection!
    rescue Mso::IntercompanyInvoices::Error, MsoSnapshot::Unusable => e
      redirect_to admin_mso_snapshot_path(resource), alert: e.message.truncate(1200)
      return
    end

    if collected
      redirect_to admin_mso_snapshot_path(resource),
        notice: "The management fee has been collected. True-ups are payable once every executive accepts."
    else
      redirect_to admin_mso_snapshot_path(resource),
        alert: "The management fee has not been collected in full. That is also the answer when a paying " \
               "company has no tracker or no invoice on the pass, an invoice is dated outside the month, or " \
               "QuickBooks holds an invoice to a payer for the month that is not attached. True-ups for this " \
               "month are not payable."
    end
  end

  show title: :display_name do
    snapshot = resource
    money = ->(value) { number_to_currency(BigDecimal(value.to_s)) }
    contributor_ids = (snapshot.lines + snapshot.benchmark_members + snapshot.excluded_without_login +
                       snapshot.income_drift_lines + snapshot.unaccepted_payouts_at_run)
      .map { |entry| entry["contributor_id"] }.uniq
    contributors = Contributor.where(id: contributor_ids).includes(:forecast_person).index_by(&:id)
    name_for = ->(id) { contributors[id]&.display_name || "Contributor ##{id}" }
    # Only the current snapshot's lines correspond to rows that exist now. A
    # superseded snapshot is drawn from its own stored lines alone: today's
    # rows belong to a later run.
    trueups = snapshot.current? ? MsoTrueup.with_deleted.where(mso_snapshot_id: snapshot.id).index_by(&:ledger_id) : {}

    if snapshot.current? && snapshot.invalidated?
      panel "THIS RUN IS NO LONGER VALID — nothing from it is payable" do
        para snapshot.invalidated_reason
        para "Invalidated #{l(snapshot.invalidated_at, format: :long)}. Run the month again from garden3d's " \
             "pass; confirming collection will not restore this run."
      end
    end

    # The nightly check (Mso::MonthlyRun.record_income_drift!). Above the
    # figures: they are the ones that no longer hold.
    if snapshot.income_drift?
      panel "FIGURES HAVE MOVED SINCE THIS RUN" do
        if snapshot.income_drift_lines.any?
          table_for snapshot.income_drift_lines do
            column("Executive") { |entry| name_for.call(entry["contributor_id"]) }
            column("True-up in this run") { |entry| money.call(entry["stored"]) }
            column("A computation now gives") { |entry| money.call(entry["now"]) }
            column("What to do") do |entry|
              entry["billed"] ? "Has a QuickBooks bill: a person decides" : "No bill: run the month again"
            end
          end
          para "Income landed, or the roster or the benchmark changed, after this month was run. A true-up " \
               "with no QuickBooks bill cannot be paid at the old figure: this run has been marked invalid and " \
               "the month has to be run again. A true-up that already has a bill is left as it is; to change " \
               "it, remove its bill from the true-up's page and run the month again."
        end
        if snapshot.income_drift_refusal
          para "The month can no longer be computed as it was run: #{snapshot.income_drift_refusal}"
        end
        if snapshot.income_drift_checked_at
          para "As of the nightly check on #{l(snapshot.income_drift_checked_at, format: :long)}."
        end
      end
    end

    if snapshot.run_warnings?
      panel "Not finished when this month was run" do
        para "The run did not wait for these. Each can still change what an executive earned in the month, " \
             "and so their true-up; the nightly check reports it above if one does."
        if snapshot.incomplete_passes_at_run.any?
          enterprise_names = Enterprise
            .where(id: snapshot.incomplete_passes_at_run.map { |entry| entry["enterprise_id"] }).pluck(:id, :name).to_h
          para "Invoice passes that had not finished invoicing: " +
               snapshot.incomplete_passes_at_run.map { |entry|
                 "InvoicePass ##{entry['invoice_pass_id']} (#{enterprise_names[entry['enterprise_id']] || 'unknown company'})"
               }.join(", ")
        end
        if snapshot.unaccepted_payouts_at_run.any?
          para "Executives' payouts nobody had accepted: " +
               snapshot.unaccepted_payouts_at_run.map { |entry|
                 "#{name_for.call(entry['contributor_id'])}: #{entry['count']} unaccepted " \
                   "(ContributorPayout #{Array(entry['contributor_payout_ids']).join(', ')})"
               }.join("; ")
        end
      end
    end

    if snapshot.over_cap?
      panel "WARNING: what is owed is more than the cap" do
        para "Counting true-ups that already have a QuickBooks bill at their billed amounts, this month's " \
             "true-ups total #{money.call(snapshot.total_trueup_as_billed)}, against a cap of " \
             "#{money.call(snapshot.cap)}. The fee income fell after a bill was written. A person has to " \
             "decide what to do about the billed rows listed under Drift."
      end
    end

    attributes_table do
      row("Month") { link_to snapshot.invoice_pass.invoice_month, admin_invoice_pass_path(snapshot.invoice_pass) }
      row("Status") do
        if snapshot.current?
          snapshot.invalidated? ? "Current, but INVALID" : "Current"
        elsif snapshot.superseded_by
          link_to "Superseded #{l(snapshot.superseded_at, format: :short)} — see the run that replaced it",
            admin_mso_snapshot_path(snapshot.superseded_by)
        else
          "Superseded"
        end
      end
      row("Run") { "#{l(snapshot.created_at, format: :long)}#{snapshot.created_by ? " by #{snapshot.created_by.email}" : ''}" }
      row("Management fee income (account 4100)") { money.call(snapshot.fee_income) }
      row("Cap") { "#{money.call(snapshot.cap)} (#{(snapshot.cap_percentage * 100).to_s('F')}% of fee income)" }
      row("Benchmark average") do
        "#{snapshot.benchmark_average} — top #{snapshot.configured_n}, #{snapshot.counted} counted" \
          "#{snapshot.small_sample ? ' (fewer earners than the setting)' : ''}"
      end
      row("Total calculated") { money.call(snapshot.total_calculated) }
      row("Total true-up") { money.call(snapshot.total_trueup) }
      row("Total true-up, counting billed rows as billed") { money.call(snapshot.total_trueup_as_billed) }
      row("Fee collected") do
        snapshot.fee_collected? ? "Confirmed #{l(snapshot.fee_collected_at, format: :short)}" : "Not confirmed"
      end
      if snapshot.current?
        row("Every expected true-up accepted") { snapshot.all_expected_trueups_accepted? ? "Yes" : "No" }
      end
    end

    if snapshot.drift.any?
      panel "Drift: true-ups that already have a QuickBooks bill and were not changed" do
        table_for snapshot.drift do
          column("True-up") { |entry| "MsoTrueup ##{entry['mso_trueup_id']}" }
          column("Billed") { |entry| money.call(entry["billed_amount"]) }
          column("This run computed") { |entry| money.call(entry["computed_amount"]) }
        end
        para "Each of these needs a person to decide what to do. To change one, remove its QuickBooks bill " \
             "from the true-up's page and run the month again."
      end
    end

    panel "Executives" do
      table_for snapshot.lines do
        column("Executive") { |line| link_to name_for.call(line["contributor_id"]), admin_contributor_path(line["contributor_id"], ledger: line["ledger_id"]) }
        column("Role") { |line| "#{line['tier'].to_s.titleize} (#{line['title']}), #{line['multiplier']}x" }
        column("Calculated") { |line| money.call(line["calculated"]) }
        column("Reduction") { |line| money.call(line["reduction"]) }
        column("After cap") { |line| money.call(line["final"]) }
        column("Already earned") { |line| money.call(line["already_earned"]) }
        column("True-up") { |line| money.call(line["trueup"]) }
        column("Row") do |line|
          trueup = trueups[line["ledger_id"]]
          if !snapshot.current?
            "As run; see the current snapshot"
          elsif trueup.nil?
            BigDecimal(line["trueup"].to_s).positive? ? "Missing" : "None owed"
          elsif trueup.deleted_at.present?
            "Removed"
          else
            link_to "#{trueup.accepted? ? 'Accepted' : 'Awaiting acceptance'}#{trueup.locked? ? ', billed' : ''} ↗",
              admin_ledger_mso_trueup_path(trueup.ledger_id, trueup)
          end
        end
      end
    end

    panel "Benchmark: the earners averaged" do
      table_for snapshot.benchmark_members do
        column("Contributor") { |member| name_for.call(member["contributor_id"]) }
        column("Qualifying income") { |member| money.call(member["amount"]) }
      end
      if snapshot.excluded_without_login.any?
        para "Left out for having no Stacks login, though they would have ranked: " +
             snapshot.excluded_without_login.map { |entry| "#{name_for.call(entry['contributor_id'])} (#{money.call(entry['amount'])})" }.join(", ")
      end
    end

    panel "Fee income reconciliation" do
      reconciliation = snapshot.reconciliation
      para "Account 4100: #{money.call(reconciliation['account_total'] || 0)}. " \
           "Managerial Services on attached invoices: #{money.call(reconciliation['payer_total'] || 0)}."
      table_for(reconciliation["invoices"] || []) do
        column("QuickBooks invoice") { |invoice| invoice["qbo_id"] }
        column("Total") { |invoice| money.call(invoice["total"]) }
        column("Managerial Services") { |invoice| money.call(invoice["managerial_services"]) }
      end
    end
  end
end
