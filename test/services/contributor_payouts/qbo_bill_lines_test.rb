require "test_helper"
require "ostruct"

class ContributorPayouts::QboBillLinesTest < ActiveSupport::TestCase
  # Synthetic CP stub. Mocha stubs:
  #   in_sync?, blueprint, amount, bill_description, find_qbo_account!
  def make_cp(blueprint:, amount:, in_sync: true, default_account: nil)
    default_account ||= OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = mock("contributor_payout")
    cp.stubs(:in_sync?).returns(in_sync)
    cp.stubs(:blueprint).returns(blueprint)
    cp.stubs(:amount).returns(amount)
    cp.stubs(:id).returns(42)
    cp.stubs(:bill_description).returns("https://example.com/cp/42")
    cp.stubs(:find_qbo_account!).returns([default_account, nil])
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

  test "multi-line happy path: 6 buckets with specific accounts where defined, fallback otherwise" do
    bonuses = OpenStruct.new(name: "Bonuses", acct_num: "5710", id: 5710)
    commissions = OpenStruct.new(name: "Commissions", acct_num: "6120", id: 6120)
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)

    cp = make_cp(blueprint: all_buckets_blueprint, amount: 129.0, default_account: default)
    qbo_accounts = [bonuses, commissions, default]

    lines = ContributorPayouts::QboBillLines.new(cp, qbo_accounts).call

    assert_equal 6, lines.size, "expected 6 lines (one per non-zero bucket)"

    by_account_id = lines.group_by { |l| l[:account].id }
    # Commission → 6120
    assert by_account_id[6120].any? { |l| l[:amount] == 10.0 }, "commission line should land at account 6120"
    # AL Surplus + PL Surplus → 5710 (two lines, same account)
    assert_equal 2, by_account_id[5710].size, "AL Surplus + PL Surplus both route to Bonuses"
    # IC + AL Base + PL Base → default
    assert_equal 3, by_account_id[1].size, "IC + AL Base + PL Base fall back to default account"

    # Line sums equal cp.amount
    assert_equal 129.0, lines.sum { |l| l[:amount] }.round(2)
  end

  test "Account Lead bucket is split into base and surplus by 'surplus revenue' marker" do
    blueprint = {
      "AccountLead" => [
        { "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8" },
        { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
    }
    bonuses = OpenStruct.new(name: "Bonuses", acct_num: "5710", id: 5710)
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 11.0, default_account: default)

    lines = ContributorPayouts::QboBillLines.new(cp, [bonuses, default]).call

    assert_equal 2, lines.size
    base_line    = lines.find { |l| l[:description].include?("Account Lead\n") }
    surplus_line = lines.find { |l| l[:description].include?("Account Lead Surplus") }
    assert_equal 8.0, base_line[:amount]
    assert_equal 3.0, surplus_line[:amount]
    assert_equal 1,    base_line[:account].id,    "AL base falls back to default"
    assert_equal 5710, surplus_line[:account].id, "AL surplus routes to Bonuses"
  end

  test "Project Lead bucket is split into base and surplus by 'surplus revenue' marker" do
    blueprint = {
      "ProjectLead" => [
        { "amount" => 5.0, "description_line" => "- 100hrs * 5% = $5" },
        { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
    }
    bonuses = OpenStruct.new(name: "Bonuses", acct_num: "5710", id: 5710)
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 8.0, default_account: default)

    lines = ContributorPayouts::QboBillLines.new(cp, [bonuses, default]).call

    assert_equal 2, lines.size
    base_line    = lines.find { |l| l[:description].include?("Project Lead\n") }
    surplus_line = lines.find { |l| l[:description].include?("Project Lead Surplus") }
    assert_equal 5.0, base_line[:amount]
    assert_equal 3.0, surplus_line[:amount]
    assert_equal 1,    base_line[:account].id
    assert_equal 5710, surplus_line[:account].id
  end

  test "zero-amount bucket is skipped" do
    blueprint = {
      "IndividualContributor" => [{ "amount" => 100.0, "description_line" => "-" }],
      "Commission"            => [],  # empty
    }
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 100.0, default_account: default)

    lines = ContributorPayouts::QboBillLines.new(cp, [default]).call

    assert_equal 1, lines.size
    assert_equal 100.0, lines.first[:amount]
  end

  test "specific account missing from qbo_accounts list → that line falls back to default" do
    blueprint = { "Commission" => [{ "amount" => 10.0, "description_line" => "-" }] }
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 10.0, default_account: default)
    # Commissions is intentionally NOT in qbo_accounts
    lines = ContributorPayouts::QboBillLines.new(cp, [default]).call

    assert_equal 1, lines.size
    assert_equal 1, lines.first[:account].id, "commission line falls back to default when Commissions missing"
  end

  test "not in_sync? → single-line collapse at default account" do
    blueprint = { "IndividualContributor" => [{ "amount" => 200.0, "description_line" => "-" }] }
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 100.0, in_sync: false, default_account: default)

    lines = ContributorPayouts::QboBillLines.new(cp, [default]).call

    assert_equal 1, lines.size
    assert_equal 100.0, lines.first[:amount], "single-line uses cp.amount, not the blueprint sum"
    assert_equal "https://example.com/cp/42", lines.first[:description]
    assert_equal 1, lines.first[:account].id
  end

  test "per-bucket sums drift from cp.amount → collapse + log WARN" do
    # blueprint sums to 105, cp.amount is 100 — drift safety triggers
    blueprint = { "IndividualContributor" => [{ "amount" => 105.0, "description_line" => "-" }] }
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 100.0, default_account: default)

    Rails.logger.expects(:warn).at_least_once
    lines = ContributorPayouts::QboBillLines.new(cp, [default]).call

    assert_equal 1, lines.size
    assert_equal 100.0, lines.first[:amount]
  end

  test "every bucket empty / zero → collapse to single line" do
    blueprint = { "IndividualContributor" => [] }
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 0.0, default_account: default)

    lines = ContributorPayouts::QboBillLines.new(cp, [default]).call

    assert_equal 1, lines.size
    assert_equal 0.0, lines.first[:amount]
  end

  test "structured AccountLeadSurplus key routes to :account_lead_surplus without parsing description_line" do
    # New blueprint shape from make_contributor_payouts!: surplus lives in its
    # own array, description_line does NOT include 'surplus revenue'.
    blueprint = {
      "AccountLead"        => [{ "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8" }],
      "AccountLeadSurplus" => [{ "amount" => 3.0, "description_line" => "- arbitrary marker-free copy" }],
    }
    bonuses = OpenStruct.new(name: "Bonuses", acct_num: "5710", id: 5710)
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 11.0, default_account: default)

    lines = ContributorPayouts::QboBillLines.new(cp, [bonuses, default]).call

    assert_equal 2, lines.size
    base_line    = lines.find { |l| l[:description].include?("Account Lead\n") }
    surplus_line = lines.find { |l| l[:description].include?("Account Lead Surplus") }
    assert_equal 8.0, base_line[:amount]
    assert_equal 3.0, surplus_line[:amount]
    assert_equal 5710, surplus_line[:account].id, "structured-key surplus still lands at Bonuses"
  end

  test "structured ProjectLeadSurplus key routes to :project_lead_surplus" do
    blueprint = {
      "ProjectLead"        => [{ "amount" => 5.0, "description_line" => "- 100hrs * 5% = $5" }],
      "ProjectLeadSurplus" => [{ "amount" => 3.0, "description_line" => "- marker-free copy" }],
    }
    bonuses = OpenStruct.new(name: "Bonuses", acct_num: "5710", id: 5710)
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 8.0, default_account: default)

    lines = ContributorPayouts::QboBillLines.new(cp, [bonuses, default]).call

    surplus_line = lines.find { |l| l[:description].include?("Project Lead Surplus") }
    assert_equal 3.0, surplus_line[:amount]
    assert_equal 5710, surplus_line[:account].id
  end

  test "mixed shape: structured AccountLeadSurplus AND legacy AccountLead with marker — both route to surplus" do
    # Defensive: a CP whose blueprint was partially regenerated could have entries
    # in BOTH the new key and the legacy mixed array. We should sum them, not drop.
    blueprint = {
      "AccountLead"        => [
        { "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8 base" },
        { "amount" => 2.0, "description_line" => "- legacy surplus revenue share = $2" },
      ],
      "AccountLeadSurplus" => [{ "amount" => 3.0, "description_line" => "- marker-free copy" }],
    }
    bonuses = OpenStruct.new(name: "Bonuses", acct_num: "5710", id: 5710)
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 13.0, default_account: default)

    lines = ContributorPayouts::QboBillLines.new(cp, [bonuses, default]).call

    surplus_line = lines.find { |l| l[:description].include?("Account Lead Surplus") }
    assert_equal 5.0, surplus_line[:amount], "structured ($3) + historical-parsed ($2) sum"
    base_line = lines.find { |l| l[:description].include?("Account Lead\n") }
    assert_equal 8.0, base_line[:amount]
  end

  test "description format: role header + entry description_lines + admin URL" do
    blueprint = {
      "Commission" => [
        { "amount" => 10.0, "description_line" => "- 5% of $200 = $10" },
        { "amount" => 5.0,  "description_line" => "- 5% of $100 = $5" },
      ],
    }
    commissions = OpenStruct.new(name: "Commissions", acct_num: "6120", id: 6120)
    default = OpenStruct.new(name: "Contractors - Client Services", id: 1)
    cp = make_cp(blueprint: blueprint, amount: 15.0, default_account: default)

    lines = ContributorPayouts::QboBillLines.new(cp, [commissions, default]).call

    desc = lines.first[:description]
    assert_match(/\A# Commission\n/, desc, "description starts with role header")
    assert_includes desc, "- 5% of $200 = $10"
    assert_includes desc, "- 5% of $100 = $5"
    assert_includes desc, "https://example.com/cp/42", "admin URL appended"
  end
end
