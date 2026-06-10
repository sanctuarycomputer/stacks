require "test_helper"
require "ostruct"

class ContributorPayouts::QboBillLinesTest < ActiveSupport::TestCase
  # Records every account_for call and returns a canned QboChartAccount-like
  # OpenStruct per line_item_key (optionally per [key, tracker_id]).
  class FakeResolver
    attr_reader :calls

    def initialize(accounts)
      @accounts = accounts
      @calls = []
    end

    def account_for(key, contributor:, project_tracker: nil)
      @calls << { key: key, tracker_id: project_tracker&.id }
      @accounts.fetch([key, project_tracker&.id]) { @accounts.fetch(key) }
    end
  end

  DEFAULT_ACCT     = OpenStruct.new(qbo_id: "100", name: "Contractors - Client Services")
  BONUSES_ACCT     = OpenStruct.new(qbo_id: "5710", name: "Bonuses")
  COMMISSIONS_ACCT = OpenStruct.new(qbo_id: "6120", name: "Commissions")
  MARKETING_ACCT   = OpenStruct.new(qbo_id: "300", name: "Contractors - Marketing Services")

  def default_accounts
    {
      "payout_individual_contributor" => DEFAULT_ACCT,
      "payout_account_lead_base"      => DEFAULT_ACCT,
      "payout_account_lead_surplus"   => BONUSES_ACCT,
      "payout_project_lead_base"      => DEFAULT_ACCT,
      "payout_project_lead_surplus"   => BONUSES_ACCT,
      "payout_commission"             => COMMISSIONS_ACCT,
    }
  end

  # Synthetic CP stub. Mocha stubs:
  #   in_sync?, blueprint, amount, bill_description, contributor, invoice_tracker
  def make_cp(blueprint:, amount:, in_sync: true, trackers: [])
    contributor = OpenStruct.new(id: 7)
    invoice_tracker = OpenStruct.new(project_trackers: trackers)
    cp = mock("contributor_payout")
    cp.stubs(:in_sync?).returns(in_sync)
    cp.stubs(:blueprint).returns(blueprint)
    cp.stubs(:amount).returns(amount)
    cp.stubs(:id).returns(42)
    cp.stubs(:bill_description).returns("https://example.com/cp/42")
    cp.stubs(:contributor).returns(contributor)
    cp.stubs(:invoice_tracker).returns(invoice_tracker)
    cp
  end

  def all_buckets_blueprint
    {
      "IndividualContributor" => [{ "amount" => 100.0, "description_line" => "- IC line" }],
      "AccountLead"           => [
        { "amount" => 8.0,  "description_line" => "- 100hrs * 8% = $8 base" },
        { "amount" => 3.0,  "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
      "ProjectLead"           => [
        { "amount" => 5.0,  "description_line" => "- 100hrs * 5% = $5 base" },
        { "amount" => 3.0,  "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
      "Commission"            => [{ "amount" => 10.0, "description_line" => "- 5% of $200 = $10" }],
    }
  end

  test "multi-line happy path: 6 buckets resolve per line_item_key" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 129.0)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 6, lines.size
    by_qbo_id = lines.group_by { |l| l[:account].qbo_id }
    assert by_qbo_id["6120"].any? { |l| l[:amount] == 10.0 }, "commission line at Commissions"
    assert_equal 2, by_qbo_id["5710"].size, "AL surplus + PL surplus at Bonuses"
    assert_equal 3, by_qbo_id["100"].size, "IC + AL base + PL base at default"
    assert_equal 129.0, lines.sum { |l| l[:amount] }.round(2)
  end

  test "splits a bucket into one line per project tracker" do
    tracker_a = OpenStruct.new(id: 1, forecast_project_ids: ["fpA"])
    tracker_b = OpenStruct.new(id: 2, forecast_project_ids: ["fpB"])
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 60.0, "description_line" => "- A work", "blueprint_metadata" => { "forecast_project" => "fpA" } },
        { "amount" => 40.0, "description_line" => "- B work", "blueprint_metadata" => { "forecast_project" => "fpB" } },
      ],
    }
    accounts = default_accounts.merge(
      ["payout_individual_contributor", 2] => MARKETING_ACCT,
    )
    resolver = FakeResolver.new(accounts)
    cp = make_cp(blueprint: blueprint, amount: 100.0, trackers: [tracker_a, tracker_b])

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 2, lines.size, "one IC line per tracker"
    line_a = lines.find { |l| l[:amount] == 60.0 }
    line_b = lines.find { |l| l[:amount] == 40.0 }
    assert_equal "100", line_a[:account].qbo_id
    assert_equal "300", line_b[:account].qbo_id, "tracker B's override account"
    assert_includes resolver.calls, { key: "payout_individual_contributor", tracker_id: 1 }
    assert_includes resolver.calls, { key: "payout_individual_contributor", tracker_id: 2 }
  end

  test "entries with no resolvable tracker group into a nil-tracker line" do
    tracker_a = OpenStruct.new(id: 1, forecast_project_ids: ["fpA"])
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 60.0, "description_line" => "- A work", "blueprint_metadata" => { "forecast_project" => "fpA" } },
        { "amount" => 40.0, "description_line" => "- orphan", "blueprint_metadata" => { "forecast_project" => "fpZ" } },
        { "amount" => 29.0, "description_line" => "- no metadata" },
      ],
    }
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: blueprint, amount: 129.0, trackers: [tracker_a])

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 2, lines.size, "tracker-A line + combined nil-tracker line"
    nil_tracker_line = lines.find { |l| l[:amount] == 69.0 }
    assert_not_nil nil_tracker_line, "orphan + metadata-less entries combine into one line"
    assert_includes resolver.calls, { key: "payout_individual_contributor", tracker_id: nil }
  end

  test "legacy mixed AccountLead arrays still split base vs surplus via the description marker" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 129.0)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    surplus_keys = resolver.calls.map { |c| c[:key] }.select { |k| k.include?("surplus") }
    assert_equal ["payout_account_lead_surplus", "payout_project_lead_surplus"].sort, surplus_keys.sort
  end

  test "out-of-sync payout collapses to a single line at payout_individual_contributor" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 999.0, in_sync: false)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 1, lines.size
    assert_equal 999.0, lines.first[:amount]
    assert_equal "100", lines.first[:account].qbo_id
    assert_equal [{ key: "payout_individual_contributor", tracker_id: nil }], resolver.calls
  end

  test "empty blueprint collapses to a single line" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: {}, amount: 50.0)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 1, lines.size
    assert_equal 50.0, lines.first[:amount]
  end

  test "a negative per-tracker group collapses to a single line" do
    tracker_a = OpenStruct.new(id: 1, forecast_project_ids: ["fpA"])
    tracker_b = OpenStruct.new(id: 2, forecast_project_ids: ["fpB"])
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 120.0, "description_line" => "- A work", "blueprint_metadata" => { "forecast_project" => "fpA" } },
        { "amount" => -20.0, "description_line" => "- B credit", "blueprint_metadata" => { "forecast_project" => "fpB" } },
      ],
    }
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: blueprint, amount: 100.0, trackers: [tracker_a, tracker_b])

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 1, lines.size, "negative group must collapse to the single-line shape"
    assert_equal 100.0, lines.first[:amount]
    assert_equal "100", lines.first[:account].qbo_id
  end

  test "bucket-sum drift from cp.amount collapses to a single line and warns" do
    blueprint = { "IndividualContributor" => [{ "amount" => 100.0, "description_line" => "- IC" }] }
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: blueprint, amount: 101.0)
    # in_sync? is stubbed true but the sums disagree — belt-and-suspenders path.

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    assert_equal 1, lines.size
    assert_equal 101.0, lines.first[:amount]
  end

  test "line descriptions keep the role header and entry lines" do
    resolver = FakeResolver.new(default_accounts)
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 129.0)

    lines = ContributorPayouts::QboBillLines.new(cp, resolver: resolver).call

    ic_line = lines.find { |l| l[:amount] == 100.0 }
    assert_match(/# Individual Contributor/, ic_line[:description])
    assert_match(/- IC line/, ic_line[:description])
    assert_match(%r{https://example.com/cp/42}, ic_line[:description])
  end
end
