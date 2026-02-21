class AssociatesAwardAgreement < ApplicationRecord
  belongs_to :admin_user

  POOL_OWNER_UNITS = 10_000_000.to_f
  INITIAL_AWARDABLE_POOL = 40_000_000.to_f

  scope :active, -> {
    joins(:admin_user).merge(AdminUser.active)
  }

  def display_name
    admin_user.email
  end

  def self.total_award_units_issued_on(date = Date.today)
    AssociatesAwardAgreement.all.map do |a|
      a.vested_units_on(date)
    end.reduce(:+) || 0
  end

  def self.pool_owner_percentage_of_pool_on(date = Date.today)
    1 - AssociatesAwardAgreement.all.map{|a| a.percentage_of_pool_on(date)}.reduce(:+)
  end

  def vesting_schedule
    floor_units = (total_awardable_units * 0.10).to_i

    initial = {
      net_vested: 0,
      pending_vest: 0,
      pending_unvest: 0,
      baseline_at_cessation: nil,
      consecutive_non_elevated: 0,
      non_elevated_month_starts: [],
      timeline: []
    }

    contributor = admin_user.forecast_person.contributor
    return initial unless contributor.present?

    ledger_asc_by_month = contributor.new_deal_ledger_items[:by_month]
      .sort_by { |period, _| period.starts_at }
      .map do |period, period_meta|
        next nil unless started_at <= period.starts_at
        { starts_at: period.starts_at, elevated_service: period_meta[:elevated_service] }
      end.compact

    ledger_asc_by_month.reduce(initial) do |st, row|
      starts_at        = row.fetch(:starts_at)
      elevated_service = row.fetch(:elevated_service)

      # --- month start state ---
      net = st[:net_vested]

      # Capture "vested as of cessation date" BEFORE applying pending vest,
      # because pending vest (from prior elevated month) occurs today (after cessation).
      net_before_pending_vest = net

      # 1) Apply pending vest/unvest scheduled from last month (effective today)
      if st[:pending_vest] > 0
        net = [net + st[:pending_vest], total_awardable_units].min
      end

      if st[:pending_unvest] > 0
        reducible = [net - floor_units, 0].max
        applied   = [st[:pending_unvest], reducible].min
        net      -= applied
      end

      pending_vest  = 0
      pending_unvest = 0

      # 2) Maintain rolling 12-month window of non-elevated months (inclusive boundary)
      cutoff = starts_at << 12
      non_elevated = st[:non_elevated_month_starts].select { |d| d >= cutoff }

      # 3) Track cessation baseline + consecutive non-elevated streak
      baseline = st[:baseline_at_cessation]
      consecutive_non_elevated = st[:consecutive_non_elevated]

      if elevated_service
        consecutive_non_elevated = 0
        baseline = nil
      else
        non_elevated << starts_at
        consecutive_non_elevated += 1

        # baseline must be vested as of the date elevated service ceased,
        # i.e. end of prior month, which equals "net before pending vest is applied today"
        baseline = net_before_pending_vest if consecutive_non_elevated == 1
      end

      # 4) Schedule next month vest/unvest based on THIS month’s status
      # Vesting: if elevated service in this month, installment vests on 1st of next month
      if elevated_service
        pending_vest = installment_amount
      end

      # Un-vesting: if NOT elevated this month, un-vest on 1st of next month (if gates met)
      if !elevated_service &&
         non_elevated.length > 4 &&
         net > floor_units &&
         baseline && baseline > 0

        # Prefer integer-safe behavior; round choice is business/legal.
        monthly_unvest = (baseline.to_f / 12.0).round

        reducible = [net - floor_units, 0].max
        pending_unvest = [monthly_unvest, reducible].min
      end

      {
        net_vested: net,
        pending_vest: pending_vest,
        pending_unvest: pending_unvest,
        baseline_at_cessation: baseline,
        consecutive_non_elevated: consecutive_non_elevated,
        non_elevated_month_starts: non_elevated,
        installment_amount: installment_amount,
        total_awardable_units: total_awardable_units,
        floor_units: floor_units,
        timeline: st[:timeline] + [{
          starts_at: starts_at,
          elevated_service: elevated_service,
          net_vested: net,
          scheduled_vest_next_month: pending_vest,
          scheduled_unvest_next_month: pending_unvest,
          rolling_non_elevated_count: non_elevated.length,
          baseline_at_cessation: baseline
        }]
      }
    end
  end

  def vested_units_on(date = Date.today, vs = vesting_schedule)
    return 0 unless vs && vs[:timeline].present?
    month_start =
      if date.respond_to?(:beginning_of_month)
        date.beginning_of_month
      else
        Date.new(date.year, date.month, 1)
      end
    entry = vs[:timeline]
      .select { |row| row[:starts_at] <= month_start }
      .max_by { |row| row[:starts_at] }
    entry ? entry[:net_vested] : 0
  end

  def percentage_of_pool_on(date = Date.today, vs = vesting_schedule)
    vested_units = vested_units_on(date, vs)
    return 0 if vested_units == 0
    total_issued = AssociatesAwardAgreement.total_award_units_issued_on(date)
    vested_units / ([total_issued, INITIAL_AWARDABLE_POOL].max + POOL_OWNER_UNITS)
  end
end
