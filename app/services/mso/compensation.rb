module Mso
  # Pure: given a benchmark average, a roster and the month's management fee
  # income, returns each executive's calculated compensation, capped final and
  # true-up. No database, no QuickBooks, no clock — the outputs are determined
  # entirely by the arguments.
  #
  # The cap is a CEILING, not a budget. Unused cap stays with garden3d and is
  # never redistributed — including the share of an executive whose true-up
  # floors at zero because they already out-earned their target. What someone
  # earns as a contributor is paid by the operating company out of project
  # economics, not out of the management fee, so it does not count against it.
  class Compensation
    DEFAULT_CAP_PERCENTAGE = BigDecimal("0.55")

    ZERO = BigDecimal("0")
    CENT = BigDecimal("0.01")

    # `key` only has to be unique across the lines. If the caller keys by role
    # period, two periods for one person become two lines and two payments —
    # the caller must make sure there is one line per person.
    Line = Struct.new(:key, :multiplier, :already_earned, keyword_init: true)
    Output = Struct.new(:key, :calculated, :final, :reduction, :trueup, keyword_init: true)
    Result = Struct.new(:outputs, :cap, :total_calculated, :total_trueup, keyword_init: true)

    def self.call(benchmark_average:, lines:, fee_income:, cap_percentage: DEFAULT_CAP_PERCENTAGE)
      new(
        benchmark_average: benchmark_average,
        lines: lines,
        fee_income: fee_income,
        cap_percentage: cap_percentage,
      ).call
    end

    def initialize(benchmark_average:, lines:, fee_income:, cap_percentage:)
      @benchmark_average = BigDecimal(benchmark_average.to_s)
      @lines = lines
      @fee_income = BigDecimal(fee_income.to_s)
      @cap_percentage = BigDecimal(cap_percentage.to_s)

      keys = lines.map(&:key)
      raise ArgumentError, "duplicate line keys: #{keys.inspect}" if keys.uniq.size != keys.size

      # A negative fee would produce a negative cap and allocate negative pay
      # against it. None of these can legitimately be below zero.
      if [@benchmark_average, @fee_income, @cap_percentage].any?(&:negative?) ||
         lines.any? { |line| BigDecimal(line.multiplier.to_s).negative? }
        raise ArgumentError, "benchmark, fee income, cap percentage and multipliers must not be negative"
      end
    end

    def call
      calculated = @lines.to_h { |line| [line.key, @benchmark_average * BigDecimal(line.multiplier.to_s)] }
      total_calculated = calculated.values.sum(ZERO)
      finals = finals_for(calculated, total_calculated)

      outputs = @lines.map do |line|
        final = finals.fetch(line.key)
        # A month of net clawbacks must not push a true-up above the final.
        earned = [ZERO, BigDecimal(line.already_earned.to_s)].max

        Output.new(
          key: line.key,
          calculated: calculated.fetch(line.key),
          final: final,
          reduction: [ZERO, calculated.fetch(line.key) - final].max,
          trueup: [ZERO, final - earned].max,
        )
      end

      Result.new(
        outputs: outputs,
        cap: cap,
        total_calculated: total_calculated,
        total_trueup: outputs.sum(ZERO, &:trueup),
      )
    end

    private

    def cap
      @cap ||= @cap_percentage * @fee_income
    end

    # The cap can carry a fraction of a cent (55% of 90,000.01). Only whole
    # cents can be paid, so this is the real ceiling for the finals.
    def payable_cap
      cap.floor(2)
    end

    def finals_for(calculated, total_calculated)
      if total_calculated > cap && total_calculated > ZERO
        scaled = calculated.transform_values { |amount| amount * (cap / total_calculated) }
        return allocate_cents(scaled, payable_cap)
      end

      # Under the cap each line stands on its own, so round it on its own.
      rounded = calculated.transform_values { |amount| amount.round(2) }
      return rounded if rounded.values.sum(ZERO) <= payable_cap

      # Rounding up pushed a total that only just fit over the ceiling.
      allocate_cents(calculated, payable_cap)
    end

    # Largest-remainder allocation: floor every line to cents, then hand out
    # the cents still owed towards `target`, biggest fractional remainder
    # first. Ties break on the key — numerically for numeric keys (record
    # ids), otherwise by its string — so the result is stable.
    def allocate_cents(amounts, target)
      floored = amounts.transform_values { |amount| amount.floor(2) }
      leftover = [((target - floored.values.sum(ZERO)) / CENT).round, 0].max

      ranked = amounts.keys.sort_by do |key|
        numeric = key.is_a?(Numeric)
        [-(amounts.fetch(key) - floored.fetch(key)), numeric ? 0 : 1, numeric ? key : key.to_s]
      end
      ranked.first(leftover).each { |key| floored[key] += CENT }
      floored
    end
  end
end
