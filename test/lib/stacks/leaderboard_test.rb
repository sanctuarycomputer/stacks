require "test_helper"

class Stacks::LeaderboardTest < ActiveSupport::TestCase
  def setup
    @admin = AdminUser.create!(
      email: "leaderboard-#{SecureRandom.hex(3)}@sanctuary.computer",
      password: "password"
    )
    @enterprise = enterprises(:sanctuary)
    @other_enterprise = enterprises(:one)
    @qbo_account = qbo_accounts(:one)

    # Far-future month so this suite never collides with other tests or with
    # the unique index on invoice_passes.start_of_month.
    @month = Date.new(2097, 3, 1)
    @pass = InvoicePass.create!(start_of_month: @month)
    @client = ForecastClient.create!(
      forecast_id: rand(1..2_000_000_000),
      name: "Leaderboard Client #{SecureRandom.hex(2)}"
    )
    @tracker = InvoiceTracker.create!(
      forecast_client: @client,
      invoice_pass: @pass,
      qbo_account: @qbo_account
    )
  end

  def make_contributor(email)
    person = ForecastPerson.create!(
      forecast_id: rand(1..2_000_000_000),
      email: email,
      data: {}
    )
    Contributor.create!(forecast_person: person)
  end

  def ledger_for(contributor, enterprise = @enterprise)
    Ledger.find_or_create_for(enterprise: enterprise, contributor: contributor)
  end

  # save(validate: false) sidesteps the 70%-of-invoice and new-deal domain
  # validations, which are irrelevant to (and would obstruct) aggregation tests.
  def payout!(contributor, amount, enterprise: @enterprise)
    ContributorPayout.new(
      ledger: ledger_for(contributor, enterprise),
      invoice_tracker: @tracker,
      created_by: @admin,
      amount: amount
    ).save!(validate: false)
  end

  def month_group
    Stacks::Leaderboard.call(limit: 5).find { |g| g.start_of_month == @month }
  end

  test "ranks contributors by summed payouts, descending, honoring the limit" do
    top = make_contributor("top@example.com")
    middle = make_contributor("middle@example.com")
    bottom = make_contributor("bottom@example.com")

    payout!(middle, 300)
    payout!(top, 500)
    payout!(bottom, 100)

    group = Stacks::Leaderboard.call(limit: 2).find { |g| g.start_of_month == @month }

    assert_equal 2, group.entries.size, "limit should cap the number of entries"
    assert_equal ["top@example.com", "middle@example.com"], group.entries.map(&:display_name)
    assert_equal [1, 2], group.entries.map(&:rank)
    assert_equal BigDecimal("500"), group.entries.first.amount
    assert_equal BigDecimal("800"), group.total, "total reflects only the listed entries"
    assert_equal BigDecimal("400"), group.average, "average is across the listed entries only"
  end

  test "average is the mean of the listed entries, not the whole collective" do
    make_contributor("a@example.com").tap { |c| payout!(c, 900) }
    make_contributor("b@example.com").tap { |c| payout!(c, 300) }
    # A third earner that falls outside a limit of 2 must not drag the average.
    make_contributor("c@example.com").tap { |c| payout!(c, 30) }

    group = Stacks::Leaderboard.call(limit: 2).find { |g| g.start_of_month == @month }

    assert_equal BigDecimal("1200"), group.total
    assert_equal BigDecimal("600"), group.average
  end

  test "excludes Trueups from earnings" do
    real_earner = make_contributor("earner@example.com")
    topped_up = make_contributor("toppedup@example.com")

    payout!(real_earner, 1_000)
    payout!(topped_up, 10)

    # A large Trueup must not lift this contributor up the board.
    Trueup.new(
      ledger: ledger_for(topped_up),
      invoice_pass: @pass,
      amount: 5_000
    ).save!(validate: false)

    group = month_group

    assert_equal "earner@example.com", group.entries.first.display_name,
      "the Trueup recipient must not outrank a genuine earner"

    topped_up_entry = group.entries.find { |e| e.display_name == "toppedup@example.com" }
    assert_equal BigDecimal("10"), topped_up_entry.amount,
      "only the payout should count, not the Trueup"
    assert_equal BigDecimal("1010"), group.total
  end

  test "sums a contributor's payouts across all of their ledgers" do
    contributor = make_contributor("multi@example.com")

    payout!(contributor, 100, enterprise: @enterprise)
    payout!(contributor, 250, enterprise: @other_enterprise)

    group = month_group
    entry = group.entries.find { |e| e.display_name == "multi@example.com" }

    assert_equal 1, group.entries.count { |e| e.display_name == "multi@example.com" },
      "a contributor appears once, aggregated across ledgers"
    assert_equal BigDecimal("350"), entry.amount
  end

  test "omits contributors with no positive earnings" do
    earner = make_contributor("positive@example.com")
    zeroed = make_contributor("zero@example.com")

    payout!(earner, 100)
    payout!(zeroed, 0)

    group = month_group

    assert_equal ["positive@example.com"], group.entries.map(&:display_name)
  end

  test "prefers a full name over the email when one is present" do
    person = ForecastPerson.create!(
      forecast_id: rand(1..2_000_000_000),
      email: "named@example.com",
      first_name: "Ada",
      last_name: "Lovelace",
      data: {}
    )
    contributor = Contributor.create!(forecast_person: person)
    payout!(contributor, 42)

    assert_equal "Ada Lovelace", month_group.entries.first.display_name
  end

  test "to_csv emits a header and one row per ranked contributor" do
    make_contributor("first@example.com").tap { |c| payout!(c, 900) }
    make_contributor("second@example.com").tap { |c| payout!(c, 300) }

    rows = CSV.parse(Stacks::Leaderboard.to_csv(limit: 5))

    assert_equal Stacks::Leaderboard::CSV_HEADERS, rows.first
    row = rows.find { |r| r[2] == "first@example.com" }
    assert_equal "2097-03", row[0], "month is ISO-ish for sorting"
    assert_equal "1", row[1], "rank"
    assert_equal "900.00", row[3], "earnings are plain decimals, not currency strings"
    assert_equal 4, row.size, "no month average/total columns"
  end

  test "to_csv honors the limit" do
    5.times { |i| make_contributor("csv#{i}@example.com").tap { |c| payout!(c, (i + 1) * 100) } }

    rows = CSV.parse(Stacks::Leaderboard.to_csv(limit: 2))
    body = rows.drop(1).select { |r| r[0] == "2097-03" }

    assert_equal 2, body.size
    assert_equal ["csv4@example.com", "csv3@example.com"], body.map { |r| r[2] }
  end

  test "to_csv escapes names containing commas" do
    person = ForecastPerson.create!(
      forecast_id: rand(1..2_000_000_000),
      email: "comma@example.com",
      first_name: "Lovelace, Ada",
      last_name: "",
      data: {}
    )
    payout!(Contributor.create!(forecast_person: person), 100)

    parsed = CSV.parse(Stacks::Leaderboard.to_csv(limit: 5))

    assert_includes parsed.map { |r| r[2] }, "Lovelace, Ada",
      "a comma in a name must survive a CSV round-trip"
  end

  test "mso_compensation scales the month average by each tier multiplier" do
    tiers = Stacks::Leaderboard.mso_compensation(BigDecimal("1000"))

    assert_equal ["Heads", "Chiefs", "Founders"], tiers.map(&:label)
    assert_equal ["0.8x", "1x", "1.2x"], tiers.map(&:multiplier_label),
      "1x renders without a trailing .0"
    assert_equal [BigDecimal("800"), BigDecimal("1000"), BigDecimal("1200")],
      tiers.map(&:amount)
  end

  test "mso_compensation handles a zero average" do
    assert_equal [0, 0, 0], Stacks::Leaderboard.mso_compensation(BigDecimal(0)).map { |t| t.amount.to_i }
  end

  test "sanitize_limit defaults, clamps, and rejects junk" do
    assert_equal 5, Stacks::Leaderboard.sanitize_limit(nil)
    assert_equal 5, Stacks::Leaderboard.sanitize_limit("")
    assert_equal 5, Stacks::Leaderboard.sanitize_limit("not-a-number")
    assert_equal 3, Stacks::Leaderboard.sanitize_limit("3")
    assert_equal 10, Stacks::Leaderboard.sanitize_limit(10)
    assert_equal 1, Stacks::Leaderboard.sanitize_limit("0"), "clamps below the minimum"
    assert_equal 1, Stacks::Leaderboard.sanitize_limit("-4"), "clamps negatives"
    assert_equal 50, Stacks::Leaderboard.sanitize_limit("999"), "clamps above the maximum"
  end
end
