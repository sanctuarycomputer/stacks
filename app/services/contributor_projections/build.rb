module ContributorProjections
  # Prices the forward plan in the local Runn mirror into projected ledger
  # lines, per (contributor, tracker, workstream, month), with the same
  # rules InvoiceTracker#make_contributor_payouts! and PayCycles::GenerateStubs
  # apply. Pure: no writes, no HTTP. Data problems never raise — they land
  # in Result#skipped with a reason.
  class Build
    Key = Struct.new(:contributor, :tracker, :forecast_project, :month)

    def self.call(horizon: Horizon.current, contributor: nil)
      new(horizon: horizon, contributor: contributor).call
    end

    # Payables page only. Keyed on today + the sync stamp so a fresh mirror
    # busts it; 1h TTL bounds staleness inside a day.
    def self.cached_all(horizon: Horizon.current)
      key = ["contributor_projections", Date.today, ContributorProjections.runn_synced_at&.to_i]
      Rails.cache.fetch(key, expires_in: 1.hour) { call(horizon: horizon) }
    end

    def initialize(horizon:, contributor: nil)
      @horizon = horizon
      @only_contributor_id = contributor&.id
      @lines = []
      @skipped = Hash.new { |h, k| h[k] = [] }
      # no_forecast_client is a property of the workstream, not of the people
      # assigned to it — count it once per workstream instead of once per
      # (contributor, month) key that happens to land on it.
      @no_forecast_client_counted = Set.new
    end

    # skipped / skipped_details are always global across every assignment,
    # even when contributor: filters lines down to one person's Result — the
    # contributor page does not render them, so this is left as-is rather
    # than filtered to match.
    def call
      load!
      hours_by_key, flags_by_key = resolve
      hours_by_key.each do |key, hours|
        price_key(key, hours, **flags_by_key[key])
      end
      project_recurring_adjustments
      lines = @only_contributor_id ? @lines.select { |l| l.contributor_id == @only_contributor_id } : @lines
      Result.new(
        horizon: @horizon,
        lines: lines,
        skipped: @skipped.transform_values(&:size),
        # Hash[] drops the default proc; a Hash with one cannot be Marshal'd,
        # and memory_store marshals every entry (cached_all would silently
        # fail forever).
        skipped_details: Hash[@skipped],
        as_of: ContributorProjections.runn_synced_at,
      )
    end

    private

    # ------------------------------------------------------------------ load

    def load!
      @assignments = RunnAssignment.plannable
        .overlapping(@horizon.starts_at, @horizon.ends_at)
        .includes(:runn_project, :runn_role, :runn_person)
        .to_a

      project_ids = @assignments.map(&:project_id).compact.uniq
      @trackers_by_runn_id = ProjectTracker
        .where(runn_project_id: project_ids)
        .includes(
          forecast_projects: { forecast_client: :enterprise },
          account_lead_periods: { admin_user: :full_time_periods },
          project_lead_periods: { admin_user: :full_time_periods },
          commissions: { contributor: { forecast_person: { admin_user: :full_time_periods } } },
        )
        .index_by(&:runn_project_id)

      # Two Forecast people can share an email; prefer the one with an
      # AdminUser, then the unarchived one (matches recent_actuals' tie-break).
      @contributors_by_email = {}
      Contributor.includes(forecast_person: { admin_user: :full_time_periods }).each do |c|
        fp = c.forecast_person
        next if fp.nil?
        email = fp.email.to_s.strip.downcase
        next if email.blank?
        existing = @contributors_by_email[email]
        @contributors_by_email[email] = c if existing.nil? || better_match?(c, existing)
      end

      # Only ids are read below, so no association needs eager loading.
      @ledgers = Ledger.all.index_by { |l| [l.enterprise_id, l.contributor_id] }
      @adjustments = RecurringLedgerAdjustment.active.includes(:ledger).to_a
      @tracker_count_by_workstream = ProjectTrackerForecastProject.group(:forecast_project_id).count
    end

    def better_match?(candidate, existing)
      c_admin = candidate.forecast_person.admin_user.present?
      e_admin = existing.forecast_person.admin_user.present?
      return c_admin if c_admin != e_admin
      !candidate.forecast_person.archived && existing.forecast_person.archived == true
    end

    # --------------------------------------------------------------- resolve

    # Sum hours into (contributor, tracker, workstream, month) keys. The real
    # builder prices one invoice line per (person, workstream) with the month's
    # summed hours and rounds once; pricing per assignment would round twice.
    def resolve
      hours_by_key = Hash.new(0.0)
      flags_by_key = Hash.new { |h, k| h[k] = { tentative: false, rate_mismatch: false } }

      @assignments.each do |a|
        if a.is_placeholder
          # A placeholder is an unfilled seat in the plan, not a person we
          # failed to map — its own reason so the notice doesn't read as a
          # data problem to go and fix.
          skip!(:placeholder, "placeholder assignment #{a.runn_id}")
          next
        end
        contributor = @contributors_by_email[a.runn_person&.email.to_s.strip.downcase]
        if contributor.nil?
          skip!(:unmapped_person, a.runn_person&.email.presence || "runn person #{a.person_id}")
          next
        end

        rp = a.runn_project
        next if rp.nil? || rp.is_archived || rp.is_template

        tracker = @trackers_by_runn_id[a.project_id]
        if tracker.nil?
          skip!(:unmapped_project, rp.name)
          next
        end
        unless a.is_billable
          skip!(:non_billable, "#{rp.name} / #{contributor.display_name}")
          next
        end

        workstream, mismatch_detail = workstream_for(tracker, a, contributor.forecast_person.email)
        if workstream.nil?
          skip!(:no_forecast_project, tracker.name)
          next
        end
        if @tracker_count_by_workstream[workstream.forecast_id].to_i > 1
          skip!(:ambiguous_tracker, workstream.name)
          next
        end
        # Only count role_rate_mismatch once we know the assignment is not
        # also being dropped as ambiguous_tracker above — otherwise a single
        # assignment on an ambiguous, rate-mismatched workstream would inflate
        # two skip counters for the one problem.
        skip!(:role_rate_mismatch, mismatch_detail) if mismatch_detail

        @horizon.months.each do |month|
          hours = a.hours_between(month.starts_at, month.ends_at)
          next if hours <= 0
          key = Key.new(contributor, tracker, workstream, month.starts_at)
          hours_by_key[key] += hours
          flags_by_key[key][:tentative] ||= (rp.is_confirmed == false)
          flags_by_key[key][:rate_mismatch] ||= mismatch_detail.present?
        end
      end

      [hours_by_key, flags_by_key]
    end

    # The Runn role's standard_rate is only a selector: pick the workstream
    # whose p/h tag equals it. It is never used as a price. A tracker can
    # carry several workstreams at the SAME rate (e.g. three $175 streams for
    # different disciplines), and price_key reads this person's per-email rate
    # override only from the workstream returned here — so among rate-matching
    # workstreams, prefer the one that actually carries an override for this
    # email. Taking the first rate match blindly silently drops the override
    # and prices the contributor off a sibling stream. Returns
    # [workstream, mismatch_detail]: mismatch_detail is nil on a clean match,
    # or the skip! detail string when the role's rate matched no workstream.
    # Does NOT call skip! itself — the caller only does that once it has also
    # ruled out ambiguous_tracker for this workstream, so skip counts stay
    # one-reason-per-problem instead of double-counting the same assignment.
    def workstream_for(tracker, assignment, email)
      workstreams = tracker.forecast_projects.to_a
      return [nil, nil] if workstreams.empty?

      rate = assignment.runn_role&.standard_rate
      matches = rate.nil? ? [] : workstreams.select { |ws| ws.hourly_rate.to_f == rate.to_f }
      if matches.any?
        override_match = matches.find { |ws| !ws.hourly_rate_override_for_email_address(email.to_s).nil? }
        return [override_match || matches.first, nil]
      end

      detail = "#{tracker.name}: Runn role rate #{rate.inspect} matches no workstream"
      [workstreams.find { |ws| !ws.archived } || workstreams.first, detail]
    end

    # ----------------------------------------------------------------- price

    def price_key(key, hours, tentative:, rate_mismatch:)
      ws = key.forecast_project
      client = ws.forecast_client
      if client.nil?
        # Distinct from resolve's no_forecast_project (tracker has no
        # workstream at all): here the workstream exists but has no Forecast
        # client, so the two skip reasons are not conflated. Counted once per
        # workstream: every contributor-month keyed to it hits the same single
        # data problem, and counting per key would inflate it arbitrarily.
        skip!(:no_forecast_client, ws.name) if @no_forecast_client_counted.add?(ws.forecast_id)
        return
      end

      email = key.contributor.forecast_person.email
      override = ws.hourly_rate_override_for_email_address(email)
      bill_rate = ws.hourly_rate.to_f
      month_end = key.month.end_of_month
      base = {
        project_tracker_id: key.tracker.id, project_tracker_name: key.tracker.name,
        month: key.month, tentative: tentative, rate_mismatch: rate_mismatch,
      }

      if client.is_internal?
        price_internal(key, hours, ws, client, override, bill_rate, month_end, base)
      else
        price_external(key, hours, ws, client, override, bill_rate, month_end, base)
      end
    end

    # Mirrors PayCycles::GenerateStubs: hours × (override || tag rate), no
    # splits, no commissions; a workstream with neither an explicit tag nor
    # an override is what GenerateStubs raises MissingRateError on. Pay
    # cycles are the path internal work actually settles through, so that is
    # what this mirrors; InvoiceTracker#make_contributor_payouts!'s internal
    # branch (which does deduct commissions) is not mirrored here.
    def price_internal(key, hours, ws, client, override, bill_rate, month_end, base)
      if override.nil? && ws.has_no_explicit_hourly_rate?
        skip!(:no_explicit_rate, "#{ws.name} / #{key.contributor.display_name}")
        return
      end
      rate = override.nil? ? bill_rate : override.to_f
      amount = (hours * rate).round(2)
      emit(key.contributor, client.enterprise, month_end, base.merge(
        kind: :pay_stub, hours: hours, rate: rate, amount: amount,
        description: "- #{fmt(hours)} hrs * #{n2c(rate)} p/h = #{n2c(amount)}",
      ))
    end

    # Mirrors InvoiceTracker#make_contributor_payouts!: commissions off the
    # top, AL and PL shares, IC remainder (or override), surplus to the leads.
    def price_external(key, hours, ws, client, override, bill_rate, month_end, base)
      tracker = key.tracker
      enterprise = client.billing_enterprise
      rules = tracker.billing_rules

      working_amount = hours * bill_rate
      commission_total = 0.0
      tracker.commissions.each do |commission|
        deduction =
          case commission
          when PerHourCommission then (hours * commission.rate.to_f).round(2)
          when PercentageCommission then (working_amount * commission.rate.to_f).round(2)
          else 0.0
          end
        next if deduction <= 0
        commission_total += deduction
        label = commission.is_a?(PerHourCommission) ? "#{n2c(commission.rate)} p/h commission" : "#{pct(commission.rate)} commission"
        emit(commission.contributor, enterprise, month_end, base.merge(
          kind: :commission, hours: hours, rate: commission.rate.to_f, amount: deduction,
          description: "- #{fmt(hours)} hrs * #{n2c(bill_rate)} p/h * #{label} = #{n2c(deduction)}",
        ))
      end
      working_amount -= commission_total

      # The real builder resolves each lead to a ForecastPerson and treats the
      # lead as present only then (invoice_tracker.rb:444/465): a lead with no
      # Forecast identity neither gets a line nor reduces the IC share.
      account_lead = lead_for_month(tracker.account_lead_periods, key.month)
      project_lead = lead_for_month(tracker.project_lead_periods, key.month)
      al_contributor = account_lead && contributor_for_admin(account_lead)
      pl_contributor = project_lead && contributor_for_admin(project_lead)
      hours_x_rate = "#{fmt(hours)} hrs * #{n2c(bill_rate)} p/h"
      basis = commission_total > 0 ? "(#{hours_x_rate}) - #{n2c(commission_total)} commission = #{n2c(working_amount)}" : hours_x_rate

      if al_contributor
        amount = (working_amount * rules.account_lead_share).round(2).to_f
        emit(al_contributor, enterprise, month_end, base.merge(
          kind: :account_lead, hours: hours, rate: bill_rate, amount: amount,
          description: "- #{basis} * #{pct(rules.account_lead_share)} = #{n2c(amount)}",
        ))
      end
      if pl_contributor
        amount = (working_amount * rules.project_lead_share).round(2).to_f
        emit(pl_contributor, enterprise, month_end, base.merge(
          kind: :project_lead, hours: hours, rate: bill_rate, amount: amount,
          description: "- #{basis} * #{pct(rules.project_lead_share)} = #{n2c(amount)}",
        ))
      end

      if override.nil?
        share = rules.ic_share(account_lead: al_contributor.present?, project_lead: pl_contributor.present?)
        ic_amount = (working_amount * share).round(2).to_f
        ic_rate = bill_rate
        ic_description = "- #{basis} * #{pct(share)} = #{n2c(ic_amount)}"
      else
        ic_amount = (hours * override.to_f).round(2)
        ic_rate = override.to_f
        ic_description = "- #{fmt(hours)} hrs * #{n2c(override)} p/h = #{n2c(ic_amount)}"
      end
      ic_line = emit(key.contributor, enterprise, month_end, base.merge(
        kind: :individual_contributor, hours: hours, rate: ic_rate, amount: ic_amount, description: ic_description,
      ))

      # The real builder only computes surplus from PERSISTED IC entries, so
      # gate on emit having actually appended the IC line rather than on the
      # local ic_amount: a zero amount, a salaried IC, or a missing ledger all
      # drop the line, and none of them may leave the leads holding surplus
      # for pay the IC never receives. (The zero-amount case is also a
      # deliberate difference from the real builder's per-payee zero check:
      # there, an IC with a 0p/h override who is also a lead on the same
      # tracker can get a persisted zero IC entry and a phantom surplus
      # computed against it — a bug in the real behavior, not a rule this
      # projection should reproduce.)
      return if ic_line.nil?
      surplus = rules.surplus_for(working_amount: working_amount, ic_amount: ic_amount)
      return unless surplus > 0
      lead_share = (surplus * rules.surplus_lead_share).round(2).to_f
      surplus_description = "- #{n2c(surplus)} surplus * #{pct(rules.surplus_lead_share)} = #{n2c(lead_share)}"
      if al_contributor
        emit(al_contributor, enterprise, month_end, base.merge(
          kind: :account_lead_surplus, hours: nil, rate: nil, amount: lead_share, description: surplus_description,
        ))
      end
      if pl_contributor
        emit(pl_contributor, enterprise, month_end, base.merge(
          kind: :project_lead_surplus, hours: nil, rate: nil, amount: lead_share, description: surplus_description,
        ))
      end
    end

    # A lead period with no explicit end is treated as continuing through
    # every future month. This deliberately differs from
    # ProjectTracker#account_lead_for_month / #project_lead_for_month, which
    # use period_ended_at instead of ended_at directly: for a nil ended_at,
    # period_ended_at falls back to the tracker's last_recorded_assignment_end_date
    # (read from the Forecast-derived snapshot). Forecast actuals cannot exist
    # for a future month, so those model helpers return nil — "not a lead" —
    # for every month beyond the last recorded assignment, including every
    # future horizon month. That is correct for their callers (current-state
    # views keyed off real, recorded assignments) but wrong here: an open
    # (still-active) lead period must not lapse just because the future has
    # no Forecast actuals yet, or an active account/project lead would never
    # be projected a share of forward-looking work. This divergence is an
    # approved design decision, not a bug — do not "fix" it to match the
    # model helpers. The start side still uses period_started_at (rather than
    # started_at directly) because most production lead-period rows have a
    # nil started_at and rely on that fallback to the tracker's first
    # recorded assignment.
    def lead_for_month(periods, month_start)
      month_end = month_start.end_of_month
      periods.find { |p| p.period_started_at <= month_end && (p.ended_at.nil? || p.ended_at >= month_start) }&.admin_user
    end

    def contributor_for_admin(admin_user)
      @contributors_by_email[admin_user.email.to_s.strip.downcase]
    end

    # Same test as InvoiceTracker#make_contributor_payouts! (:532) and
    # PayCycles::GenerateStubs#salaried_skip?: only a covering full-time
    # period that is NOT variable_hours excludes a payee.
    def paid_on_ledger?(admin_user, date)
      return true if admin_user.nil?
      ftp = admin_user.full_time_period_at(date)
      ftp.nil? || ftp.variable_hours?
    end

    # Returns the appended Line, or nil when the payee was dropped. Callers
    # that derive a second line from a first one (surplus off the IC line)
    # MUST gate on the return value, not on the amount they passed in.
    def emit(contributor, enterprise, month_end, attrs)
      if contributor.nil? || enterprise.nil?
        # A commission recipient with no contributor, or a Forecast client
        # with no billing enterprise: the money has nowhere to land.
        skip!(:no_payee, "#{attrs[:kind]} on #{attrs[:project_tracker_name]}")
        return nil
      end
      return nil if attrs[:amount].to_f == 0
      return nil unless paid_on_ledger?(contributor.forecast_person&.admin_user, month_end)

      ledger = @ledgers[[enterprise.id, contributor.id]]
      if ledger.nil?
        skip!(:no_ledger, "#{contributor.display_name} / #{enterprise.name}")
        return nil
      end
      line = Line.new(attrs.merge(ledger_id: ledger.id, enterprise_id: enterprise.id, contributor_id: contributor.id))
      @lines << line
      line
    end

    # ------------------------------------------------- recurring adjustments

    def project_recurring_adjustments
      @adjustments.each do |rla|
        # advance raises ArgumentError on a cadence it doesn't recognize (e.g.
        # a row whose cadence was forced past validation). Data problems never
        # raise here — catch it, skip! this one row, and move on to the rest.
        begin
          due = rla.next_due_on
          while due <= @horizon.ends_at
            if due >= @horizon.starts_at
              @lines << Line.new(
                kind: :recurring_adjustment,
                ledger_id: rla.ledger_id, enterprise_id: rla.ledger.enterprise_id, contributor_id: rla.ledger.contributor_id,
                project_tracker_id: nil, project_tracker_name: rla.description,
                hours: nil, rate: nil, amount: rla.amount.to_f.round(2),
                description: "- #{rla.description} (#{rla.cadence.humanize.downcase}, due #{due.strftime('%b %-d')})",
                tentative: false, rate_mismatch: false, month: due.beginning_of_month,
              )
            end
            due = rla.advance(due)
          end
        rescue ArgumentError => e
          skip!(:invalid_recurring_adjustment, "##{rla.id}: #{e.message}")
        end
      end
    end

    # --------------------------------------------------------------- helpers

    def skip!(reason, detail)
      @skipped[reason] << detail.to_s
    end

    # Float#to_s gives "40.0" / "12.5" / "26.25" — the same shape the payout
    # builder's description lines use.
    def fmt(hours)
      hours.to_f.round(2).to_s
    end

    def pct(share)
      "#{(share.to_f * 100).round(2)}%"
    end

    def n2c(*args)
      ActionController::Base.helpers.number_to_currency(*args)
    end
  end
end
