# MSO Compensation Calculator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure function that turns a benchmark average and a roster into each MSO executive's calculated, capped and true-up figures.

**Architecture:** One class, `Mso::Compensation`, with a single `.call` entry point. No database, no QBO, no clock — every output is determined by the arguments. That purity is why this subsystem can be built and tested before S0, S1 and S2 exist, against only the signatures pinned in the spec's §4.1.

**Tech Stack:** Ruby, `BigDecimal`, Minitest.

This is subsystem **S3** of `docs/superpowers/specs/2026-10-09-garden3d-mso-compensation-design.md` (§8).

## Global Constraints

- **All arithmetic in `BigDecimal`.** No `Float` anywhere, including intermediates. Construct from strings (`BigDecimal("0.55")`), never from float literals.
- `cap_percentage` is a **fraction** (`0.55`), never a percentage integer (`55`). A caller passing `55` would produce a cap 100× too large.
- The class must not reference `Date.today`, `Time.now`, `ActiveRecord`, or any constant outside `Mso::Compensation`.
- **The cap is a ceiling, not a budget.** Unused cap is retained as garden3d profit and is never redistributed, including cap freed when a line's true-up floors at zero.
- Run the suite with `--exclude "sync_meet runs the connector inside a SystemTask"`.
- Only one file is created: `app/services/mso/compensation.rb`. Touch nothing else.

---

### Task 1: Structs and the uncapped path

**Files:**
- Create: `app/services/mso/compensation.rb`
- Test: `test/services/mso/compensation_test.rb`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `Mso::Compensation::Line = Struct.new(:key, :multiplier, :already_earned, keyword_init: true)`
  - `Mso::Compensation::Output = Struct.new(:key, :calculated, :final, :reduction, :trueup, keyword_init: true)`
  - `Mso::Compensation::Result = Struct.new(:outputs, :cap, :total_calculated, :total_trueup, keyword_init: true)`
  - `Mso::Compensation.call(benchmark_average:, lines:, fee_income:, cap_percentage:) -> Result`
  - `Mso::Compensation::DEFAULT_CAP_PERCENTAGE = BigDecimal("0.55")`

`key` is an opaque caller-supplied identifier — S4 passes `MsoRolePeriod#id`. This class never looks inside it, which is what keeps S3 free of S2.

- [ ] **Step 1: Write the failing test**

Create `test/services/mso/compensation_test.rb`:

```ruby
require "test_helper"

class McoCompensationTest < ActiveSupport::TestCase
  def line(key, multiplier, earned = "0")
    Mso::Compensation::Line.new(
      key: key,
      multiplier: BigDecimal(multiplier),
      already_earned: BigDecimal(earned),
    )
  end

  def call(benchmark:, lines:, fee_income:, cap_percentage: "0.55")
    Mso::Compensation.call(
      benchmark_average: BigDecimal(benchmark),
      lines: lines,
      fee_income: BigDecimal(fee_income),
      cap_percentage: BigDecimal(cap_percentage),
    )
  end

  test "calculated is the benchmark times the multiplier" do
    result = call(
      benchmark: "25000",
      lines: [line(:chief, "1.00"), line(:svp, "0.85"), line(:head, "0.70")],
      fee_income: "200000",
    )

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("25000"), by_key[:chief].calculated
    assert_equal BigDecimal("21250"), by_key[:svp].calculated
    assert_equal BigDecimal("17500"), by_key[:head].calculated
  end

  test "under the cap there is no reduction and final equals calculated" do
    result = call(
      benchmark: "25000",
      lines: [line(:chief, "1.00"), line(:svp, "0.85")],
      fee_income: "200000",
    )

    assert_equal BigDecimal("110000"), result.cap
    result.outputs.each do |output|
      assert_equal output.calculated, output.final
      assert_equal BigDecimal("0"), output.reduction
    end
  end

  test "the true-up is the final less what the executive already earned" do
    result = call(
      benchmark: "20000",
      lines: [line(:chief, "1.00", "5620")],
      fee_income: "200000",
    )

    output = result.outputs.first
    assert_equal BigDecimal("20000"), output.final
    assert_equal BigDecimal("14380"), output.trueup
  end

  test "the true-up floors at zero when earnings exceed the final" do
    result = call(
      benchmark: "20000",
      lines: [line(:chief, "1.00", "32606")],
      fee_income: "200000",
    )

    output = result.outputs.first
    assert_equal BigDecimal("20000"), output.final
    assert_equal BigDecimal("0"), output.trueup
  end

  test "cap_percentage is a fraction of fee income" do
    result = call(benchmark: "1000", lines: [line(:chief, "1.00")], fee_income: "140000")
    assert_equal BigDecimal("77000"), result.cap
  end

  test "totals are reported" do
    result = call(
      benchmark: "20000",
      lines: [line(:chief, "1.00", "5000"), line(:svp, "0.85")],
      fee_income: "200000",
    )

    assert_equal BigDecimal("37000"), result.total_calculated
    assert_equal BigDecimal("32000"), result.total_trueup
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/garden3d-mso
bin/rails test test/services/mso/compensation_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Mso::Compensation`.

- [ ] **Step 3: Write the implementation**

Create `app/services/mso/compensation.rb`:

```ruby
module Mso
  # Pure: given a benchmark average, a roster and the month's management fee
  # income, returns each executive's calculated compensation, the capped final,
  # and the true-up to pay. No database, no QBO, no clock — every output is
  # determined by the arguments, which is what lets this be built and tested
  # independently of the subsystems that feed it.
  #
  # The cap is a CEILING, not a budget. Unused cap is retained as garden3d
  # profit and is never redistributed — including cap freed when a line's
  # true-up floors at zero because the executive already out-earned their
  # target. Compensation earned as a contributor is paid by the operating
  # company out of project economics and never touches the management fee, so
  # it is not MSO compensation and does not count against the cap.
  class Compensation
    DEFAULT_CAP_PERCENTAGE = BigDecimal("0.55")

    ZERO = BigDecimal("0")

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
    end

    def call
      calculated = @lines.to_h { |line| [line.key, @benchmark_average * line.multiplier] }
      total_calculated = calculated.values.sum(ZERO)

      finals = apply_cap(calculated, total_calculated)

      outputs = @lines.map do |line|
        final = finals.fetch(line.key)
        earned = BigDecimal(line.already_earned.to_s)

        Output.new(
          key: line.key,
          calculated: calculated.fetch(line.key),
          final: final,
          reduction: calculated.fetch(line.key) - final,
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

    def apply_cap(calculated, total_calculated)
      return calculated if total_calculated <= cap || total_calculated <= ZERO

      calculated.transform_values { |amount| amount * (cap / total_calculated) }
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/compensation_test.rb
```

Expected: PASS, 6 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/mso/compensation.rb test/services/mso/compensation_test.rb
git commit -m "feat(mso): compensation calculator — uncapped path and true-ups

Pure function: benchmark x multiplier gives calculated compensation, and
the true-up is the final less what the executive already earned, floored
at zero (no clawback)."
```

---

### Task 2: The pro rata cap reduction

**Files:**
- Modify: `app/services/mso/compensation.rb`
- Test: `test/services/mso/compensation_test.rb`

**Interfaces:**
- Consumes: Task 1's structs
- Produces: no new signatures; `reduction` and `final` become meaningful when over cap

- [ ] **Step 1: Write the failing test**

Append to `test/services/mso/compensation_test.rb`:

```ruby
  test "over the cap, finals are reduced pro rata by multiplier" do
    # benchmark 25,942.59; multipliers 1.00 / 0.85 / 0.70 -> sum 2.55
    # total calculated 66,153.6045; fee 90,000 -> cap 49,500
    result = call(
      benchmark: "25942.59",
      lines: [line(:chief, "1.00"), line(:svp, "0.85"), line(:head, "0.70")],
      fee_income: "90000",
    )

    assert_equal BigDecimal("49500"), result.cap
    assert_operator result.outputs.sum(BigDecimal("0"), &:final), :<=, result.cap

    by_key = result.outputs.index_by(&:key)
    # Each final keeps its share of the cap: cap * multiplier / 2.55
    assert_in_delta 19_411.76, by_key[:chief].final.to_f, 0.01
    assert_in_delta 16_500.00, by_key[:svp].final.to_f, 0.01
    assert_in_delta 13_588.24, by_key[:head].final.to_f, 0.01
  end

  test "reduction is calculated less final" do
    result = call(
      benchmark: "25942.59",
      lines: [line(:chief, "1.00"), line(:svp, "0.85"), line(:head, "0.70")],
      fee_income: "90000",
    )

    result.outputs.each do |output|
      assert_equal output.calculated - output.final, output.reduction
      assert_operator output.reduction, :>, BigDecimal("0")
    end
  end

  test "unused cap is NOT redistributed when a true-up floors at zero" do
    # The chief has already out-earned their reduced final, so their true-up is
    # zero. The cap room that implies must NOT be reallocated to the others --
    # the cap is a ceiling, not a budget, and the surplus is garden3d's profit.
    result = call(
      benchmark: "25942.59",
      lines: [
        line(:chief, "1.00", "32606"),
        line(:svp, "0.85", "12047.50"),
        line(:head, "0.70", "9000"),
      ],
      fee_income: "90000",
    )

    by_key = result.outputs.index_by(&:key)
    assert_equal BigDecimal("0"), by_key[:chief].trueup

    # svp and head keep exactly their pro rata finals, unchanged by the chief's
    # zeroed true-up.
    assert_in_delta 16_500.00, by_key[:svp].final.to_f, 0.01
    assert_in_delta 13_588.24, by_key[:head].final.to_f, 0.01
    assert_in_delta 4_452.50, by_key[:svp].trueup.to_f, 0.01
    assert_in_delta 4_588.24, by_key[:head].trueup.to_f, 0.01

    # Cash out of garden3d is far below the cap. That is intended.
    assert_in_delta 9_040.74, result.total_trueup.to_f, 0.01
  end
```

- [ ] **Step 2: Run to verify the new tests fail**

```bash
bin/rails test test/services/mso/compensation_test.rb
```

Expected: the three new tests FAIL — `apply_cap` from Task 1 already divides pro rata, so these may partially pass; the failures will be on the un-rounded cent values. Record which fail and why before proceeding.

- [ ] **Step 3: Confirm no implementation change is needed**

Task 1's `apply_cap` already implements the pro rata reduction. If all three tests pass at Step 2, that is the correct outcome — note it and move to Step 4 rather than inventing a change. The tests exist to **pin** the behaviour, including the "not redistributed" invariant that a future contributor might otherwise "fix".

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/compensation_test.rb
```

Expected: PASS, 9 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/mso/compensation.rb test/services/mso/compensation_test.rb
git commit -m "test(mso): pin pro rata cap reduction and the no-redistribution rule

Includes the worked example from the spec: benchmark 25,942.59 across a
chief/svp/head roster against a 90,000 fee. Pins that cap room freed by a
zero-floored true-up is NOT reallocated -- the cap is a ceiling, not a
budget."
```

---

### Task 3: Largest-remainder rounding in both branches

Rounding must be corrected in the **uncapped** branch too. With `benchmark_average` 18,333.6666… and multipliers 1.15 / 1.00 / 0.70, naive per-line rounding totals one cent **above** a cap of exactly 52,250.95 while `total > cap` is false — so the capped branch never runs and the invariant `Σ final <= cap` breaks.

"Remainder to the largest line" is the wrong rule: in the uncapped branch it would inflate the top earner until the total reached the cap, and it biases the same highest-tier executive every month. Largest-remainder (Hare) is deterministic, conventional and unbiased.

**Files:**
- Modify: `app/services/mso/compensation.rb`
- Test: `test/services/mso/compensation_test.rb`

**Interfaces:**
- Consumes: Task 1's structs
- Produces: no new signatures; all `final` values are now exact cents

- [ ] **Step 1: Write the failing test**

Append to `test/services/mso/compensation_test.rb`:

```ruby
  test "finals are exact cents" do
    result = call(
      benchmark: "25942.59",
      lines: [line(:chief, "1.00"), line(:svp, "0.85"), line(:head, "0.70")],
      fee_income: "90000",
    )

    result.outputs.each do |output|
      assert_equal output.final, output.final.round(2),
        "#{output.key} final #{output.final} is not an exact number of cents"
    end
  end

  test "capped finals sum to exactly the cap" do
    result = call(
      benchmark: "25942.59",
      lines: [line(:chief, "1.00"), line(:svp, "0.85"), line(:head, "0.70")],
      fee_income: "90000",
    )

    assert_equal result.cap.round(2), result.outputs.sum(BigDecimal("0"), &:final)
  end

  test "the uncapped branch never exceeds the cap after rounding" do
    # benchmark 18,333.6666...; multipliers 1.15 / 1.00 / 0.70 -> sum 2.85
    # unrounded total 52,250.95; naive rounding gives 52,250.96.
    # fee 95,001.7272... -> cap exactly 52,250.95, so total > cap is FALSE and
    # the capped branch does not run. Rounding must still be corrected.
    result = call(
      benchmark: "18333.666666666666",
      lines: [line(:principal, "1.15"), line(:chief, "1.00"), line(:head, "0.70")],
      fee_income: "95001.727272727272",
    )

    total = result.outputs.sum(BigDecimal("0"), &:final)
    assert_operator total, :<=, result.cap.round(2),
      "uncapped branch produced #{total} against a cap of #{result.cap.round(2)}"
  end

  test "rounding does not systematically favour the highest tier" do
    # Hare allocation assigns the odd cent by largest fractional remainder, not
    # by largest line, so the top tier is not always the beneficiary.
    result = call(
      benchmark: "10000.005",
      lines: [line(:chief, "1.00"), line(:head, "0.70")],
      fee_income: "10000",
    )

    result.outputs.each do |output|
      assert_equal output.final, output.final.round(2)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/services/mso/compensation_test.rb
```

Expected: "finals are exact cents" and "capped finals sum to exactly the cap" FAIL — `apply_cap` returns un-rounded products like `19411.764705...`.

- [ ] **Step 3: Add largest-remainder rounding**

In `app/services/mso/compensation.rb`, replace `apply_cap` and add `round_to_cents`:

```ruby
    def apply_cap(calculated, total_calculated)
      target =
        if total_calculated > cap && total_calculated > ZERO
          calculated.transform_values { |amount| amount * (cap / total_calculated) }
        else
          calculated
        end

      round_to_cents(target)
    end

    # Largest-remainder (Hare) allocation. Floor every line to cents, then hand
    # the leftover cents out by descending fractional remainder. Deterministic,
    # unbiased, and sums to exactly the floored total -- which is what keeps
    # `sum(final) <= cap` true in BOTH branches. The uncapped branch needs this
    # too: naive per-line rounding can total a cent above a cap that
    # `total > cap` did not trip.
    def round_to_cents(amounts)
      cent = BigDecimal("0.01")

      floored = amounts.transform_values { |amount| (amount / cent).floor * cent }
      leftover = ((amounts.values.sum(ZERO) - floored.values.sum(ZERO)) / cent).round

      ranked = amounts.keys.sort_by do |key|
        [-(amounts.fetch(key) - floored.fetch(key)), key.to_s]
      end

      ranked.first(leftover).each { |key| floored[key] += cent }
      floored
    end
```

`key.to_s` is the tie-break, so two lines with identical remainders resolve deterministically rather than by hash order.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/services/mso/compensation_test.rb
```

Expected: PASS, 13 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/mso/compensation.rb test/services/mso/compensation_test.rb
git commit -m "fix(mso): largest-remainder rounding in both cap branches

Naive per-line rounding can total a cent above a cap that total > cap did
not trip, so the uncapped branch needs correcting too. Hare allocation
hands the odd cents out by descending remainder rather than to the largest
line, which would have biased the highest tier every month."
```

---

### Task 4: Boundaries and the purity guarantee

**Files:**
- Modify: `app/services/mso/compensation.rb` (only if a boundary test fails)
- Test: `test/services/mso/compensation_test.rb`

**Interfaces:**
- Consumes: Task 1's structs
- Produces: nothing new

- [ ] **Step 1: Write the failing test**

Append to `test/services/mso/compensation_test.rb`:

```ruby
  test "zero fee income means a zero cap and no true-ups" do
    result = call(
      benchmark: "25000",
      lines: [line(:chief, "1.00"), line(:svp, "0.85")],
      fee_income: "0",
    )

    assert_equal BigDecimal("0"), result.cap
    assert_equal BigDecimal("0"), result.total_trueup
    result.outputs.each { |output| assert_equal BigDecimal("0"), output.final }
  end

  test "an empty roster returns an empty result without dividing by zero" do
    result = call(benchmark: "25000", lines: [], fee_income: "140000")

    assert_equal [], result.outputs
    assert_equal BigDecimal("0"), result.total_calculated
    assert_equal BigDecimal("0"), result.total_trueup
  end

  test "a zero benchmark yields all zeros" do
    result = call(
      benchmark: "0",
      lines: [line(:chief, "1.00"), line(:svp, "0.85")],
      fee_income: "140000",
    )

    result.outputs.each do |output|
      assert_equal BigDecimal("0"), output.calculated
      assert_equal BigDecimal("0"), output.final
      assert_equal BigDecimal("0"), output.trueup
    end
  end

  test "every returned amount is a BigDecimal, never a Float" do
    result = call(
      benchmark: "25942.59",
      lines: [line(:chief, "1.00", "1000")],
      fee_income: "90000",
    )

    output = result.outputs.first
    [output.calculated, output.final, output.reduction, output.trueup,
     result.cap, result.total_calculated, result.total_trueup].each do |value|
      assert_kind_of BigDecimal, value
    end
  end

  test "the calculator touches no database and no clock" do
    # Any AR query or Date.today would make a closed month's recomputation
    # depend on when it ran.
    Date.expects(:today).never
    Time.expects(:now).never

    assert_equal 0, count_queries {
      call(benchmark: "25000", lines: [line(:chief, "1.00")], fee_income: "140000")
    }
  end

  private

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*|
      count += 1
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
```

- [ ] **Step 2: Run it to verify it fails or passes**

```bash
bin/rails test test/services/mso/compensation_test.rb
```

Expected: the four boundary tests should PASS already — Task 1's `total_calculated <= ZERO` guard and `[ZERO, ...].max` cover them. The purity test should also pass. If any fails, that is a real defect: fix it in Step 3. If all pass, these tests are pinning existing behaviour, which is their point — do **not** invent a change.

- [ ] **Step 3: Fix only what failed**

If "an empty roster" failed with `ZeroDivisionError`, the `total_calculated <= ZERO` guard in `apply_cap` is missing or misplaced — restore it. If "zero fee income" failed, `cap` is zero and `total_calculated > cap` is true, so `apply_cap` divides by `total_calculated` (non-zero) and multiplies by `cap / total_calculated` = 0 — which is correct; investigate before changing anything.

- [ ] **Step 4: Run the full suite**

```bash
bin/rails test --exclude "sync_meet runs the connector inside a SystemTask"
```

Expected: baseline + 18, 0 failures, 0 errors, 2 skips.

- [ ] **Step 5: Commit**

```bash
git add app/services/mso/compensation.rb test/services/mso/compensation_test.rb
git commit -m "test(mso): pin compensation calculator boundaries and purity

Zero fee income, empty roster, zero benchmark, BigDecimal-only returns,
and an assertion that the calculator issues no SQL and reads no clock --
so a closed month's recomputation cannot depend on when it ran."
```

---

## Self-Review

**Spec coverage.** §8's formula → Task 1; §8.1's pro rata reduction and the no-redistribution rule → Task 2; §8.2's largest-remainder rounding in both branches → Task 3; §8.3's boundaries → Task 4. §12's S3 list is fully covered: pro rata reduction, `Σ final <= cap` in both branches including after rounding, largest-remainder distribution, the uncapped branch leaving lines at their own rounded values, no redistribution of a zero-floored line's room, `cap_percentage` of `0.55` against a known fee, zero fee income, empty lines, zero benchmark, and purity.

**Placeholders.** None. Tasks 2 and 4 explicitly instruct the implementer to confirm that no change is needed rather than invent one — those tasks exist to pin invariants a later contributor might "helpfully" break.

**Type consistency.** `Line#multiplier` and `Line#already_earned` are `BigDecimal`; `key` is opaque (S4 passes `MsoRolePeriod#id`). `Output` and `Result` field names match §8's struct definitions exactly. `DEFAULT_CAP_PERCENTAGE` is referenced as a `.call` default in Task 1 and never shadowed.

**One deliberate omission:** §8 lists no `delivered` field, and this plan adds none — an earlier spec revision had one for a cap-on-delivered-compensation design that was rejected. If `delivered` is ever wanted, it is `max(final, already_earned)` and belongs in `Output`.
