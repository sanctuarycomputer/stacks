# MSO Compensation Calculator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure function that turns a benchmark average and a roster into each MSO executive's calculated compensation, capped final, and true-up.

**Architecture:** One class, `Mso::Compensation`, with a single `.call`. No database, no QuickBooks, no clock — every output is determined by the arguments.

**Tech Stack:** Ruby, `BigDecimal`, Minitest.

This is subsystem **S3** of `docs/superpowers/specs/2026-10-09-garden3d-mso-compensation-design.md` (§8).

Every expected value below was produced by running this exact implementation in standalone Ruby, and the cap invariant was fuzzed over 50,000 random rosters with zero violations.

## Global Constraints

- **All arithmetic in `BigDecimal`**, built from strings. No `Float`.
- `cap_percentage` is a **fraction** (`0.55`), never `55`.
- **The cap is a ceiling, not a budget.** Unused cap stays with garden3d and is never redistributed — including the share of an executive whose true-up floors at zero.
- The file must not reference `Date`, `Time`, `ActiveRecord`, `Rails`, or any model.
- Run tests with `--exclude "sync_meet runs the connector inside a SystemTask"`; never run two test processes at once.
- Creates exactly two files. Touch nothing else.

## The rules

```
calculated_i = benchmark_average * multiplier_i
cap          = cap_percentage * fee_income
payable_cap  = cap floored to cents          # what can actually be paid

if Σ calculated > cap:
    scale every line by cap / Σ calculated, then round so the finals
    sum to exactly payable_cap (largest-remainder allocation)
else:
    round each line to cents on its own
    (if that happens to sum above payable_cap, allocate to payable_cap instead)

reduction_i = max(0, calculated_i - final_i)
trueup_i    = max(0, final_i - already_earned_i)
```

Largest-remainder allocation: floor every line to cents, then hand the leftover cents out one each, largest fractional remainder first (ties broken by `key.to_s`, which is lexicographic). It never favours the biggest line as such.

---

### Task 1: `Mso::Compensation`

**Files:**
- Create: `app/services/mso/compensation.rb`
- Create: `test/services/mso/compensation_test.rb`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `Mso::Compensation.call(benchmark_average:, lines:, fee_income:, cap_percentage: DEFAULT_CAP_PERCENTAGE) -> Result`
  - `Mso::Compensation::Line = Struct.new(:key, :multiplier, :already_earned, keyword_init: true)` — `key` is an opaque identifier chosen by the caller and must be unique across `lines`
  - `Mso::Compensation::Output = Struct.new(:key, :calculated, :final, :reduction, :trueup, keyword_init: true)`
  - `Mso::Compensation::Result = Struct.new(:outputs, :cap, :total_calculated, :total_trueup, keyword_init: true)`
  - `Mso::Compensation::DEFAULT_CAP_PERCENTAGE = BigDecimal("0.55")`

- [ ] **Step 1: Write the failing test**

Create `test/services/mso/compensation_test.rb`:

```ruby
require "test_helper"

class Mso::CompensationTest < ActiveSupport::TestCase
  def line(key, multiplier, earned = "0")
    Mso::Compensation::Line.new(
      key: key,
      multiplier: BigDecimal(multiplier),
      already_earned: BigDecimal(earned),
    )
  end

  def compute(benchmark:, lines:, fee_income:, cap_percentage: "0.55")
    Mso::Compensation.call(
      benchmark_average: BigDecimal(benchmark),
      lines: lines,
      fee_income: BigDecimal(fee_income),
      cap_percentage: BigDecimal(cap_percentage),
    )
  end

  def roster(chief_earned = "0", svp_earned = "0", head_earned = "0")
    [line(:chief, "1.00", chief_earned), line(:svp, "0.85", svp_earned), line(:head, "0.70", head_earned)]
  end

  def sum_of_finals(result)
    result.outputs.sum(BigDecimal("0"), &:final)
  end

  # --- the formula -----------------------------------------------------------

  test "calculated is the benchmark times the multiplier" do
    result = compute(benchmark: "25000", lines: roster, fee_income: "200000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("25000"), by_key[:chief].calculated
    assert_equal BigDecimal("21250"), by_key[:svp].calculated
    assert_equal BigDecimal("17500"), by_key[:head].calculated
  end

  test "the cap is cap_percentage, a fraction, times fee income" do
    result = compute(benchmark: "1000", lines: [line(:chief, "1.00")], fee_income: "140000")
    assert_equal BigDecimal("77000"), result.cap
  end

  test "the default cap percentage is 55%" do
    result = Mso::Compensation.call(benchmark_average: BigDecimal("1000"), lines: [line(:chief, "1.00")],
                                    fee_income: BigDecimal("100000"))
    assert_equal BigDecimal("55000"), result.cap
  end

  test "under the cap there is no reduction and final equals calculated" do
    result = compute(benchmark: "25000", lines: roster, fee_income: "200000")

    assert_equal BigDecimal("110000"), result.cap
    result.outputs.each do |output|
      assert_equal output.calculated, output.final
      assert_equal BigDecimal("0"), output.reduction
    end
  end

  test "the true-up is the final less what the executive already earned" do
    result = compute(benchmark: "20000", lines: [line(:chief, "1.00", "5620")], fee_income: "200000")

    output = result.outputs.first
    assert_equal BigDecimal("20000"), output.final
    assert_equal BigDecimal("14380"), output.trueup
  end

  test "the true-up floors at zero when earnings exceed the final" do
    result = compute(benchmark: "20000", lines: [line(:chief, "1.00", "32606")], fee_income: "200000")

    assert_equal BigDecimal("20000"), result.outputs.first.final
    assert_equal BigDecimal("0"), result.outputs.first.trueup
  end

  test "totals are reported" do
    result = compute(benchmark: "20000",
                     lines: [line(:chief, "1.00", "5000"), line(:svp, "0.85")], fee_income: "200000")

    assert_equal BigDecimal("37000"), result.total_calculated
    assert_equal BigDecimal("32000"), result.total_trueup
  end

  # --- the cap ---------------------------------------------------------------

  test "over the cap, finals are reduced pro rata and sum to exactly the cap" do
    # total calculated 66,153.6045 against a cap of 49,500
    result = compute(benchmark: "25942.59", lines: roster, fee_income: "90000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("49500"), result.cap
    assert_equal BigDecimal("19411.76"), by_key[:chief].final
    assert_equal BigDecimal("16500.00"), by_key[:svp].final
    assert_equal BigDecimal("13588.24"), by_key[:head].final
    assert_equal BigDecimal("49500"), sum_of_finals(result)
  end

  test "reduction is what the cap took off" do
    result = compute(benchmark: "25942.59", lines: roster, fee_income: "90000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("6530.83"), by_key[:chief].reduction
    result.outputs.each do |output|
      assert_equal output.calculated - output.final, output.reduction
      assert_operator output.reduction, :>, BigDecimal("0")
    end
  end

  test "unused cap is NOT redistributed when a true-up floors at zero" do
    # The chief already out-earned their reduced final, so their true-up is
    # zero. That room must not flow to the others: the cap is a ceiling, not a
    # budget, and what is not paid stays with garden3d.
    result = compute(benchmark: "25942.59", lines: roster("32606", "12047.50", "9000"), fee_income: "90000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("0"), by_key[:chief].trueup
    assert_equal BigDecimal("16500.00"), by_key[:svp].final
    assert_equal BigDecimal("13588.24"), by_key[:head].final
    assert_equal BigDecimal("4452.50"), by_key[:svp].trueup
    assert_equal BigDecimal("4588.24"), by_key[:head].trueup
    assert_equal BigDecimal("9040.74"), result.total_trueup
  end

  # --- rounding --------------------------------------------------------------

  test "finals are exact cents" do
    result = compute(benchmark: "25942.59", lines: roster, fee_income: "90000")

    result.outputs.each do |output|
      assert_equal output.final.round(2), output.final, "#{output.key} is not whole cents"
    end
  end

  test "a cap with a fraction of a cent is never exceeded" do
    # 55% of 90,000.01 is 49,500.0055. Finals must total 49,500.00, not .01.
    result = compute(benchmark: "25942.59", lines: roster, fee_income: "90000.01")

    assert_equal BigDecimal("49500.0055"), result.cap
    assert_operator sum_of_finals(result), :<=, result.cap
    assert_equal BigDecimal("49500.00"), sum_of_finals(result)
  end

  test "under the cap, each line is rounded on its own" do
    # 25,000.004 and 21,250.0034 each round down; together they would round up.
    result = compute(benchmark: "25000.004", lines: [line(:chief, "1.00"), line(:svp, "0.85")],
                     fee_income: "1000000")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("25000.00"), by_key[:chief].final
    assert_equal BigDecimal("21250.00"), by_key[:svp].final
  end

  test "rounding cannot lift the total above a cap the unrounded total just met" do
    # Two lines of 10,000.005 total exactly the cap of 20,000.01. Rounding each
    # up would pay 20,000.02.
    result = compute(benchmark: "10000.005", lines: [line(:a, "1.00"), line(:b, "1.00")],
                     fee_income: "20000.01", cap_percentage: "1")

    assert_equal result.cap, result.total_calculated
    assert_equal BigDecimal("20000.01"), sum_of_finals(result)
    assert_equal [BigDecimal("10000.01"), BigDecimal("10000.00")], result.outputs.map(&:final)
  end

  test "the odd cent goes to the largest remainder, not the largest line" do
    # 100 split 1.00 : 0.70 is 58.8235 / 41.1765. The smaller line has the
    # bigger remainder, so it gets the cent.
    result = compute(benchmark: "1000", lines: [line(:chief, "1.00"), line(:head, "0.70")],
                     fee_income: "100", cap_percentage: "1")

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("58.82"), by_key[:chief].final
    assert_equal BigDecimal("41.18"), by_key[:head].final
  end

  # --- boundaries ------------------------------------------------------------

  test "zero fee income means a zero cap and no true-ups" do
    result = compute(benchmark: "25000", lines: roster, fee_income: "0")

    assert_equal BigDecimal("0"), result.cap
    assert_equal BigDecimal("0"), result.total_trueup
    result.outputs.each { |output| assert_equal BigDecimal("0"), output.final }
  end

  test "an empty roster returns an empty result" do
    result = compute(benchmark: "25000", lines: [], fee_income: "140000")

    assert_equal [], result.outputs
    assert_equal BigDecimal("0"), result.total_calculated
    assert_equal BigDecimal("0"), result.total_trueup
  end

  test "a zero benchmark yields all zeros" do
    result = compute(benchmark: "0", lines: roster, fee_income: "140000")

    result.outputs.each do |output|
      assert_equal BigDecimal("0"), output.calculated
      assert_equal BigDecimal("0"), output.final
      assert_equal BigDecimal("0"), output.trueup
    end
  end

  test "duplicate line keys are rejected" do
    error = assert_raises(ArgumentError) do
      compute(benchmark: "1000", lines: [line(:a, "1.00"), line(:a, "0.70")], fee_income: "1000")
    end
    assert_match(/duplicate line keys/, error.message)
  end

  test "integer keys work, as the true-up subsystem will pass record ids" do
    result = compute(benchmark: "1000", lines: [line(7, "1.00"), line(12, "0.70")], fee_income: "100000")
    assert_equal [7, 12], result.outputs.map(&:key)
  end

  # --- purity ----------------------------------------------------------------

  test "every amount is a BigDecimal" do
    result = compute(benchmark: "25942.59", lines: [line(:chief, "1.00", "1000")], fee_income: "90000")

    output = result.outputs.first
    [output.calculated, output.final, output.reduction, output.trueup,
     result.cap, result.total_calculated, result.total_trueup].each do |value|
      assert_kind_of BigDecimal, value
    end
  end

  test "the same inputs always give the same outputs, with no database access" do
    queries = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*| queries += 1 }

    first = compute(benchmark: "25942.59", lines: roster("100"), fee_income: "90000")
    second = compute(benchmark: "25942.59", lines: roster("100"), fee_income: "90000")

    assert_equal first.outputs.map(&:to_a), second.outputs.map(&:to_a)
    assert_equal 0, queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "the calculator's source reaches for no clock, model or framework" do
    source = File.read(Rails.root.join("app/services/mso/compensation.rb")).gsub(/^\s*#.*$/, "")
    refute_match(/\bDate\b|\bTime\b|ActiveRecord|Rails\.|\.where\(|\.find/, source)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
bin/rails test test/services/mso/compensation_test.rb
```

Expected: the run fails with `NameError: uninitialized constant Mso` (or `Mso::Compensation`) — nothing under `app/services/mso/` exists yet, so the test file may not even load. Either form is the expected red state.

- [ ] **Step 3: Write the implementation**

Create `app/services/mso/compensation.rb`:

```ruby
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
    end

    def call
      calculated = @lines.to_h { |line| [line.key, @benchmark_average * line.multiplier] }
      total_calculated = calculated.values.sum(ZERO)
      finals = finals_for(calculated, total_calculated)

      outputs = @lines.map do |line|
        final = finals.fetch(line.key)
        earned = BigDecimal(line.already_earned.to_s)

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
    # first. Ties break on key.to_s (lexicographic) so the result is stable.
    def allocate_cents(amounts, target)
      floored = amounts.transform_values { |amount| amount.floor(2) }
      leftover = [((target - floored.values.sum(ZERO)) / CENT).round, 0].max

      ranked = amounts.keys.sort_by { |key| [-(amounts.fetch(key) - floored.fetch(key)), key.to_s] }
      ranked.first(leftover).each { |key| floored[key] += CENT }
      floored
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/compensation_test.rb
```

Expected: PASS, 23 runs, 0 failures, 0 errors.

- [ ] **Step 5: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: the previous total plus 23, with 0 failures, 0 errors, 2 skips. Report the actual total.

- [ ] **Step 6: Commit**

```bash
git add app/services/mso/compensation.rb test/services/mso/compensation_test.rb
git commit -m "feat(mso): compensation calculator

Pure function: benchmark x tier multiplier, capped pro rata at a share of
management fee income, then trued up against what each executive already
earned. The cap is a ceiling, not a budget -- unused room is never
redistributed. Finals are whole cents and never total more than the cap,
including when the cap itself carries a fraction of a cent."
```

---

## Self-Review

**Spec coverage.** §8 structs and the fraction-not-percent rule; §8.1's single-pass cap on `Σ calculated`, pro rata reduction, floored true-up and no redistribution; §8.2's rounding (largest remainder when capped, each line on its own when not, never above the cap); §8.3's boundaries; and §12's S3 list all have a test above.

**Differences from the spec, to carry back into it:**

1. The ceiling the finals respect is the cap **floored to cents** (`payable_cap`). The spec's `Σ final <= cap` is unachievable otherwise when 55% of the fee has a fraction of a cent, which is the ordinary case.
2. Under the cap, lines are rounded individually rather than by largest remainder — two lines of `x.004` should each round down even though their sum rounds up. Largest remainder applies only when a total has to be hit.
3. `reduction` is floored at zero, so ordinary rounding up by half a cent never reports a negative reduction.
4. Duplicate `key`s raise.

**Placeholders.** None.

**Type consistency.** `Line`, `Output` and `Result` field names match spec §8. S2's `MsoRolePeriod#tier_multiplier` is the `BigDecimal` that `Line#multiplier` takes.
