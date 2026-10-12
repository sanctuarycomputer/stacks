# app/services/invoice_payouts/build.rb
module InvoicePayouts
  # Everything InvoiceTracker#make_contributor_payouts! will pay, computed in
  # memory with no writes: base shares per line (commission, Account Lead,
  # Project Lead, Individual Contributor) and the lead surplus shares on top.
  # The write saves exactly what this returns, so MarginCheck can rule on an
  # invoice before anything touches the database.
  class Build
    BASE_ROLES = %w[AccountLead ProjectLead IndividualContributor Commission].freeze
    SURPLUS_ROLES = %w[AccountLeadSurplus ProjectLeadSurplus].freeze

    Entry = Struct.new(:role, :payee, :amount, :description_line, :rate_override, :metadata, keyword_init: true) do
      def to_blueprint
        { "blueprint_metadata" => metadata, "amount" => amount, "description_line" => description_line }.compact
      end
    end

    Line = Struct.new(:qbo_line_item, :metadata, :project_tracker, :rules, :billed, :commission_total, :working_amount, :entries, keyword_init: true)

    Payee = Struct.new(:forecast_person, :payable, :entries, keyword_init: true) do
      def amount
        entries.sum(&:amount).round(2).to_f
      end

      def commission_amount
        entries.select { |e| e.role == "Commission" }.sum(&:amount).to_f
      end

      def blueprint
        bp = BASE_ROLES.index_with { [] }
        entries.each { |e| (bp[e.role] ||= []) << e.to_blueprint }
        bp
      end
    end

    def initialize(invoice_tracker)
      @invoice_tracker = invoice_tracker
    end

    attr_reader :invoice_tracker

    def lines
      compute
      @lines
    end

    def payees
      compute
      @payees.values
    end

    def paid_payees
      payees.select { |p| p.payable && p.amount != 0 }
    end

    def paid?(forecast_person)
      paid_payees.any? { |p| p.forecast_person == forecast_person }
    end

    def paid_commissions_by_line
      paid_payees.flat_map(&:entries).select { |e| e.role == "Commission" }.each_with_object(Hash.new(0.0)) do |e, h|
        h[e.metadata["id"].to_s] += e.amount
      end
    end

    # Existing payouts the write would normally delete as no longer earned,
    # but cannot: their QBO bill has payments against it. They stay on the
    # tracker, so they stay in the pool.
    def retained_orphans
      @retained_orphans ||= begin
        enterprise = invoice_tracker.forecast_client.billing_enterprise
        kept_ledger_ids = paid_payees.filter_map do |p|
          contributor = p.forecast_person.contributor
          contributor && Ledger.find_by(enterprise: enterprise, contributor: contributor)&.id
        end
        invoice_tracker.contributor_payouts.reload.reject { |cp| kept_ledger_ids.include?(cp.ledger_id) }.select do |cp|
          cp.qbo_bill&.has_payments?
        end
      end
    end

    private

    def invoice_pass
      invoice_tracker.invoice_pass
    end

    def end_of_month
      invoice_pass.start_of_month.end_of_month
    end

    def n2c(*args, **kwargs)
      ActionController::Base.helpers.number_to_currency(*args, **kwargs)
    end

    # Only people on variable hours (or with no AdminUser / employment history
    # at all) are paid per invoice; everyone else is salaried.
    def payable?(forecast_person)
      admin_user = forecast_person.admin_user
      admin_user.nil? || admin_user.full_time_periods.empty? || admin_user.full_time_period_at(end_of_month).variable_hours?
    end

    def add_entry(line, role:, payee:, amount:, description_line: nil, rate_override: false, metadata: nil)
      entry = Entry.new(
        role: role,
        payee: payee,
        amount: amount,
        description_line: description_line,
        rate_override: rate_override,
        metadata: ContributorPayout.slim_metadata(metadata || line.metadata),
      )
      line.entries << entry
      @payees[payee] ||= Payee.new(forecast_person: payee, payable: false, entries: [])
      @payees[payee].entries << entry
      entry
    end

    def compute
      return if @computed
      @lines = []
      @payees = {}
      blueprint_lines = ((invoice_tracker.blueprint || {})["lines"] || {}).values

      invoice_tracker.qbo_invoice.line_items.each do |line_item|
        metadata = blueprint_lines.find { |l| l["id"] == line_item["id"] }
        next unless metadata.present?

        forecast_project = ForecastProject.includes(:forecast_client).find(metadata["forecast_project"])
        next unless forecast_project.present?

        if forecast_project.forecast_client.is_internal?
          compute_internal_line(line_item, metadata)
        else
          compute_client_line(line_item, metadata, forecast_project)
        end
      end

      # Payability is only asked of people who are actually owed something:
      # full_time_period_at can be nil for someone with no period this month.
      @payees.each_value { |p| p.payable = p.amount != 0 && payable?(p.forecast_person) }

      compute_surplus
      @computed = true
    end

    def new_line(line_item, metadata, project_tracker)
      line = Line.new(
        qbo_line_item: line_item,
        metadata: metadata,
        project_tracker: project_tracker,
        rules: project_tracker&.billing_rules,
        billed: line_item["amount"].to_f,
        commission_total: 0.0,
        working_amount: line_item["amount"].to_f,
        entries: [],
      )
      @lines << line
      line
    end

    # Commissions come off the top of a line before any other share.
    def deduct_commissions(line)
      return 0.0 unless line.project_tracker
      deductions = invoice_tracker.commission_deductions_for_line(line.project_tracker, line.qbo_line_item, line.metadata)
      deductions.each do |d|
        recipient = d[:commission].contributor.forecast_person
        next unless recipient.present?
        add_entry(line,
          role: "Commission",
          payee: recipient,
          amount: d[:amount],
          description_line: d[:commission].description_line(line.qbo_line_item, line.metadata, d[:amount]))
      end
      line.commission_total = deductions.sum { |d| d[:amount] }
    end

    # Internal projects may or may not have a ProjectTracker. The IC takes the
    # whole line, less any commissions.
    def compute_internal_line(line_item, metadata)
      individual_contributor = ForecastPerson.find(metadata["forecast_person"])
      return unless individual_contributor.present?

      ptfps = ProjectTrackerForecastProject.includes(:project_tracker).where(forecast_project_id: metadata["forecast_project"])
      line = new_line(line_item, metadata, ptfps.first&.project_tracker)
      commission_total = deduct_commissions(line)
      line.working_amount = (line.billed - commission_total).round(2)
      add_entry(line, role: "IndividualContributor", payee: individual_contributor, amount: line.working_amount)
    end

    def compute_client_line(line_item, metadata, forecast_project)
      ptfps = ProjectTrackerForecastProject.includes(:project_tracker).where(forecast_project_id: metadata["forecast_project"])
      raise "Multiple project trackers found for forecast project #{metadata["forecast_project"]}" if ptfps.length > 1
      raise "No project trackers found for forecast project #{metadata["forecast_project"]}" if ptfps.length == 0

      pt = ptfps.first.project_tracker
      line = new_line(line_item, metadata, pt)
      rules = line.rules

      working_amount = line.billed
      working_hours = metadata["quantity"].to_f
      working_rate = metadata["unit_price"].to_f

      commission_total = deduct_commissions(line)
      working_amount -= commission_total

      if invoice_pass.start_of_month == Date.new(2025, 6, 1)
        # The New Deal began mid-June 2025: only the second half of that month counts.
        working_hours =
          ForecastAssignment
            .where(
              'end_date >= ? AND start_date <= ? AND project_id = ? AND person_id = ?',
              Date.new(2025, 6, 16),
              Date.new(2025, 6, 30),
              metadata["forecast_project"],
              metadata["forecast_person"]
            ).map do |a|
              a.allocation_during_range_in_hours(Date.new(2025, 6, 16), Date.new(2025, 6, 30))
            end.compact.sum
        working_amount = working_hours * working_rate
        working_amount -= commission_total
      end
      line.working_amount = working_amount

      lead_line = lambda do |share, amount|
        if commission_total > 0
          "- (#{working_hours} hrs * #{n2c(working_rate)} p/h) - #{n2c(commission_total)} commission = #{n2c(working_amount)} * #{(share * 100).round(2)}% = #{n2c(amount)}"
        else
          "- #{working_hours} hrs * #{n2c(working_rate)} p/h * #{(share * 100).round(2)}% = #{n2c(amount)}"
        end
      end

      account_lead = pt.account_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
      if account_lead.present?
        amount = (working_amount * rules.account_lead_share).round(2).to_f
        add_entry(line, role: "AccountLead", payee: account_lead, amount: amount, description_line: lead_line.call(rules.account_lead_share, amount))
      end

      project_lead = pt.project_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
      if project_lead.present?
        amount = (working_amount * rules.project_lead_share).round(2).to_f
        add_entry(line, role: "ProjectLead", payee: project_lead, amount: amount, description_line: lead_line.call(rules.project_lead_share, amount))
      end

      individual_contributor = ForecastPerson.find(metadata["forecast_person"])
      return unless individual_contributor.present?

      hourly_rate_of_pay_override = forecast_project.hourly_rate_override_for_email_address(individual_contributor.email)
      if hourly_rate_of_pay_override.present?
        amount = (working_hours * hourly_rate_of_pay_override).round(2).to_f
        add_entry(line,
          role: "IndividualContributor",
          payee: individual_contributor,
          amount: amount,
          rate_override: true,
          description_line: "- #{working_hours} hrs * #{n2c(hourly_rate_of_pay_override)} p/h = #{n2c(amount)}")
      else
        ic_share = rules.ic_share(account_lead: account_lead.present?, project_lead: project_lead.present?)
        amount = (working_amount * ic_share).round(2).to_f
        add_entry(line, role: "IndividualContributor", payee: individual_contributor, amount: amount, description_line: lead_line.call(ic_share, amount))
      end
    end

    # When an IC is paid below the model's ceiling, the line's margin above
    # the threshold is surplus, and each lead takes a share of it. Mirrors
    # ContributorPayout#calculate_surplus, which reads the same figures back
    # from saved payouts: the working amount is the billed line less the
    # commissions actually paid on it, and only paid ICs generate surplus.
    def compute_surplus
      paid = @payees.values.select(&:payable)
      paid_commissions = Hash.new(0.0)
      paid.flat_map(&:entries).each { |e| paid_commissions[e.metadata["id"]] += e.amount if e.role == "Commission" }

      paid.each do |payee|
        payee.entries.select { |e| e.role == "IndividualContributor" }.each do |ic|
          line = @lines.find { |l| l.entries.any? { |e| e.equal?(ic) } }
          pt = line.project_tracker
          next unless pt.present?

          rules = pt.billing_rules
          surplus = rules.surplus_for(working_amount: line.billed - paid_commissions[ic.metadata["id"]], ic_amount: ic.amount)
          next unless surplus > 0

          lead_share = (surplus * rules.surplus_lead_share).round(2).to_f
          lead_pct = "#{(rules.surplus_lead_share * 100).round(2)}%"
          description = line.qbo_line_item.dig("description")

          account_lead = pt.account_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
          if account_lead.present? && payable?(account_lead)
            add_entry(line,
              role: "AccountLeadSurplus",
              payee: account_lead,
              amount: lead_share,
              metadata: ic.metadata,
              description_line: "- #{n2c(surplus)} * #{lead_pct} = #{n2c(lead_share)} (`#{description}` generated #{n2c(surplus)} surplus revenue, #{lead_pct} of which is shared with the Account Lead)")
            @payees[account_lead].payable = true
          end

          project_lead = pt.project_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
          if project_lead.present? && payable?(project_lead)
            add_entry(line,
              role: "ProjectLeadSurplus",
              payee: project_lead,
              amount: lead_share,
              metadata: ic.metadata,
              description_line: "- #{n2c(surplus)} * #{lead_pct} = #{n2c(lead_share)} (`#{description}` generated #{n2c(surplus)} surplus revenue, #{lead_pct} of which is shared with the Project Lead)")
            @payees[project_lead].payable = true
          end
        end
      end
    end
  end
end
