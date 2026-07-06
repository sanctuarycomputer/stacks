module PayCycles
  # Daily cron that opens the next pay cycle for each enterprise whose
  # `pay_cycle_cadence` is set, once that cycle's end date has arrived.
  #
  # The rule: a cycle is opened (created in Stacks) on or after its
  # `ends_at` date so we never have an "in-flight" cycle whose hours
  # haven't fully accumulated yet. Once opened, stubs are auto-generated
  # from Forecast; admins then review + accept each one.
  #
  # Bootstrap (no prior cycle): use the cadence-derived range CONTAINING
  # today's date — e.g., enable monthly cadence on April 28 → cron on
  # May 1 doesn't open yet (April's cycle ends Apr 30, < today); cron on
  # May 1 also no-ops because the *current* default range (May 1–31)
  # hasn't ended either; cron on June 1 opens May 1–31.
  #
  # Subsequent cycles: append immediately after the latest sibling
  # (`starts_at = latest.ends_at + 1.day`), respecting the contiguous-
  # timeline validation on PayCycle.
  class OpenScheduledCycles
    Result = Struct.new(:enterprise, :cycle, :error, keyword_init: true) do
      def ok? = error.nil?
    end

    # Runs the cron across all cadence-enabled enterprises. Errors from one
    # enterprise (e.g., MissingRateError, unexpected exceptions) do NOT
    # abort the whole run — each enterprise's result is captured and the
    # iteration continues. Returns an array of Result structs; if any have
    # `error` present, the rake task raises an aggregate so SystemTask
    # records the failure but the successful cycles are already persisted.
    def self.call
      results = Enterprise.where.not(pay_cycle_cadence: nil).find_each.map do |enterprise|
        begin
          cycle = open_cycle_for(enterprise)
          Result.new(enterprise: enterprise, cycle: cycle, error: nil)
        rescue => e
          Rails.logger.error("[PayCycles::OpenScheduledCycles] enterprise=#{enterprise.id} failed: #{e.class}: #{e.message}")
          Result.new(enterprise: enterprise, cycle: nil, error: e)
        end
      end

      failures = results.reject(&:ok?)
      if failures.any?
        msg = failures.map { |r| "enterprise=#{r.enterprise.id} (#{r.enterprise.name}): #{r.error.class}: #{r.error.message}" }.join("; ")
        raise "OpenScheduledCycles partial failure (#{failures.size} of #{results.size}): #{msg}"
      end

      # Caller convenience: return just the cycles that were actually opened
      # (skipping the nil ones where no cycle was due yet).
      results.map(&:cycle).compact
    end

    def self.open_cycle_for(enterprise)
      return nil if enterprise.pay_cycle_cadence.blank?

      latest = enterprise.pay_cycles.order(ends_at: :desc).first
      next_starts_at = latest ? latest.ends_at + 1.day : bootstrap_starts_at(enterprise)
      return nil if next_starts_at.nil?

      next_ends_at = compute_ends_at(enterprise, next_starts_at)
      return nil if next_ends_at.nil?

      # Only open the cycle once its end date has arrived (or passed).
      # Avoids creating empty cycles whose stubs would be incomplete.
      return nil unless Date.today >= next_ends_at

      cycle = enterprise.pay_cycles.create!(
        starts_at: next_starts_at,
        ends_at: next_ends_at,
      )

      # Generate stubs immediately so admin sees a populated cycle on the
      # day it opens. If generation fails (e.g., MissingRateError because
      # a forecast project lacks a rate), DON'T roll back the cycle — the
      # cycle row is valid and useful (admin can fix the rate then regen).
      # We swallow the error here, log it, and let the .call wrapper
      # propagate it via the aggregate raise so the cron SystemTask
      # records the failure visibly.
      begin
        PayCycles::GenerateStubs.call(cycle)
      rescue => e
        Rails.logger.error("[PayCycles::OpenScheduledCycles] cycle=#{cycle.id} opened but GenerateStubs failed: #{e.class}: #{e.message}")
        raise
      end
      cycle
    end

    # The cycle that ENDED just before (or exactly on) today. We never want
    # to open the cycle currently containing today (its hours aren't done
    # accumulating); we want the one whose window already closed.
    def self.bootstrap_starts_at(enterprise)
      range = enterprise.pay_cycle_default_range_for(Date.today)
      return nil if range.nil?
      # If today falls inside the default range, that range hasn't ended
      # yet — bootstrap from the PREVIOUS range instead.
      if range.cover?(Date.today)
        previous_anchor = range.first - 1.day
        previous_range = enterprise.pay_cycle_default_range_for(previous_anchor)
        return previous_range&.first
      end
      range.first
    end

    def self.compute_ends_at(enterprise, starts_at)
      case enterprise.pay_cycle_cadence
      when "monthly"
        starts_at.end_of_month
      when "twice_monthly"
        if starts_at.day <= 15
          Date.new(starts_at.year, starts_at.month, 15)
        else
          starts_at.end_of_month
        end
      end
    end
  end
end
