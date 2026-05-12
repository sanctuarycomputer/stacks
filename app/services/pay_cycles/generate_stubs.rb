module PayCycles
  class GenerateStubs
    class MissingRateError < StandardError; end
    class AcceptedStubMissingHoursError < StandardError; end

    attr_reader :pay_cycle

    def initialize(pay_cycle)
      @pay_cycle = pay_cycle
    end

    def self.call(pay_cycle)
      new(pay_cycle).call
    end

    # Idempotent. Pro-rates each qualifying assignment to the cycle window,
    # groups by contributor, and emits/updates one PayStub per contributor.
    # Preserves accepted_at when amount is unchanged; resets when it changes.
    # Soft-deletes stubs whose contributor no longer has qualifying hours
    # (raises if the stub was already accepted).
    def call
      ActiveRecord::Base.transaction do
        per_contributor = group_qualifying_by_contributor
        validate_all_rates_resolvable!(per_contributor)
        synced_stub_ids = upsert_stubs(per_contributor)
        soft_delete_missing_stubs(synced_stub_ids)
      end
      pay_cycle.reload
    end

    # Reuses the existing rate hierarchy used by InvoiceTracker#make_contributor_payouts!:
    # per-email override on the forecast project's notes wins, else the project's hourly_rate.
    def resolve_rate(forecast_project, email)
      override = forecast_project.hourly_rate_override_for_email_address(email)
      return override.to_f if override.present?
      rate = forecast_project.hourly_rate
      return nil if rate.blank?
      rate.to_f
    end

    # Returns ForecastAssignments overlapping this cycle whose project's
    # forecast_client.is_internal? AND whose forecast_client is mapped to
    # this cycle's enterprise.
    def qualifying_assignments
      internal_names = ForecastClient::INTERNAL_CLIENTS

      ForecastAssignment
        .joins(forecast_project: :forecast_client)
        .joins("INNER JOIN enterprise_forecast_clients efc ON efc.forecast_client_id = forecast_clients.forecast_id")
        .where(forecast_clients: { name: internal_names })
        .where("efc.enterprise_id = ?", pay_cycle.enterprise_id)
        .where("forecast_assignments.start_date <= ?", pay_cycle.ends_at)
        .where("forecast_assignments.end_date >= ?", pay_cycle.starts_at)
        .includes(:forecast_person, forecast_project: :forecast_client)
    end

    # Mirrors invoice_tracker.rb:467's guard. Salaried (non-variable_hours) people
    # are paid via their full-time arrangement, not pay stubs.
    def salaried_skip?(forecast_person)
      admin_user = forecast_person.admin_user
      return false if admin_user.nil?
      return false if admin_user.full_time_periods.empty?
      ftp = admin_user.full_time_period_at(pay_cycle.ends_at)
      return false if ftp.nil?
      !ftp.variable_hours?
    end

    private

    def group_qualifying_by_contributor
      assignments_by_fp = qualifying_assignments.group_by(&:forecast_person)
      assignments_by_fp.reject { |fp, _| salaried_skip?(fp) }
    end

    # ForecastProject#hourly_rate has a system default (175) so we can't fall back to nil.
    # Use has_no_explicit_hourly_rate? as the signal that there's no explicit rate on the
    # project, and combine with per-email override absence to identify missing rates.
    def validate_all_rates_resolvable!(per_contributor)
      missing = []
      per_contributor.each do |fp, assignments|
        assignments.each do |a|
          override = a.forecast_project.hourly_rate_override_for_email_address(fp.email)
          if override.blank? && a.forecast_project.has_no_explicit_hourly_rate?
            project_label = begin
              a.forecast_project.display_name
            rescue
              a.forecast_project.name || a.project_id.to_s
            end
            missing << "#{project_label} / #{fp.email}"
          end
        end
      end
      return if missing.empty?
      raise MissingRateError, "Missing explicit hourly rate (no per-email override and no XXp/h tag) for: #{missing.join('; ')}"
    end

    def upsert_stubs(per_contributor)
      ids = []
      per_contributor.each do |fp, assignments|
        fp.ensure_contributor_exists!
        contributor = fp.contributor
        ledger = Ledger.find_or_create_for(enterprise: pay_cycle.enterprise, contributor: contributor)
        lines = build_lines(fp, assignments)
        amount = lines.sum { |l| l["amount"].to_f }.round(2)
        next if amount.zero?

        stub = PayStub.with_deleted.find_or_initialize_by(pay_cycle_id: pay_cycle.id, ledger_id: ledger.id)
        preserve_acceptance = stub.persisted? && stub.amount.to_f.round(2) == amount
        stub.assign_attributes(
          amount: amount,
          blueprint: { "lines" => lines },
          deleted_at: nil,
        )
        unless preserve_acceptance
          stub.accepted_at = nil
          stub.accepted_by_id = nil
        end
        stub.save!
        ids << stub.id
      end
      ids
    end

    def build_lines(forecast_person, assignments)
      assignments.map do |a|
        hours = a.allocation_during_range_in_hours(pay_cycle.starts_at, pay_cycle.ends_at)
        rate = resolve_rate(a.forecast_project, forecast_person.email)
        amount = (hours * rate).round(2)
        project_label = begin
          a.forecast_project.display_name
        rescue
          a.forecast_project.name || a.project_id.to_s
        end
        {
          "forecast_project" => a.project_id,
          "hours" => hours,
          "rate" => rate,
          "amount" => amount,
          "description" => "#{project_label} — #{hours}h × $#{rate}",
        }
      end
    end

    def soft_delete_missing_stubs(synced_stub_ids)
      pay_cycle.pay_stubs.where.not(id: synced_stub_ids).each do |orphan|
        if orphan.accepted_at.present?
          raise AcceptedStubMissingHoursError, "PayStub ##{orphan.id} (#{orphan.ledger.contributor.forecast_person.email}) was already accepted but has no qualifying hours after regen."
        end
        orphan.destroy
      end
    end
  end
end
