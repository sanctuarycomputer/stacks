require "test_helper"
require "ostruct"

class ContributorPayoutQboBillLinesTest < ActiveSupport::TestCase
  # Studio label used to derive bucket-specific account names like
  # "Contractors - Account Lead - Engineering".
  STUDIO_LABEL = "Engineering".freeze

  setup do
    @default_account = OpenStruct.new(id: "default-acct", name: "Contractors - Client Services")

    @ic_account              = OpenStruct.new(id: "acct-ic",  name: "Contractors - Individual Contributor - #{STUDIO_LABEL}")
    @al_base_account         = OpenStruct.new(id: "acct-alb", name: "Contractors - Account Lead - #{STUDIO_LABEL}")
    @al_surplus_account      = OpenStruct.new(id: "acct-als", name: "Contractors - Account Lead Surplus - #{STUDIO_LABEL}")
    @pl_base_account         = OpenStruct.new(id: "acct-plb", name: "Contractors - Project Lead - #{STUDIO_LABEL}")
    @pl_surplus_account      = OpenStruct.new(id: "acct-pls", name: "Contractors - Project Lead Surplus - #{STUDIO_LABEL}")
    @commission_account      = OpenStruct.new(id: "acct-com", name: "Contractors - Commission - #{STUDIO_LABEL}")

    @all_specific_accounts = [
      @default_account,
      @ic_account, @al_base_account, @al_surplus_account,
      @pl_base_account, @pl_surplus_account, @commission_account,
    ]
  end

  # Builds a stubbed ContributorPayout. Pass overrides for blueprint, amount, etc.
  def build_cp(blueprint:, amount:, in_sync: true, studio_label: STUDIO_LABEL, qbo_accounts:)
    cp = mock("contributor_payout")
    cp.stubs(:id).returns(42)
    cp.stubs(:blueprint).returns(blueprint)
    cp.stubs(:amount).returns(amount)
    cp.stubs(:in_sync?).returns(in_sync)
    cp.stubs(:bill_description).returns("https://stacks.garden3d.net/admin/invoice_trackers/1/contributor_payouts/42")
    cp.stubs(:find_qbo_account!).with(qbo_accounts).returns([@default_account, stub_studio(studio_label)])

    contributor = mock("contributor")
    forecast_person = mock("forecast_person")
    studio = stub_studio(studio_label)
    forecast_person.stubs(:studio).returns(studio)
    contributor.stubs(:forecast_person).returns(forecast_person)
    cp.stubs(:contributor).returns(contributor)

    cp
  end

  def stub_studio(label)
    return nil if label == :no_studio
    studio = mock("studio")
    cats = label.nil? ? nil : Array(label)
    studio.stubs(:qbo_subcontractors_categories).returns(cats)
    studio
  end

  test "multi-line happy path: 6 buckets populated, all bucket-specific accounts present" do
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 100.0, "description_line" => "- 10 hrs * $10 p/h = $100.00" },
      ],
      "AccountLead" => [
        { "amount" => 80.0,  "description_line" => "- 8% of $1000 base = $80.00" },
        { "amount" => 15.0,  "description_line" => "- $100 * 15% = $15.00 surplus revenue share for Account Lead" },
      ],
      "ProjectLead" => [
        { "amount" => 50.0,  "description_line" => "- 5% of $1000 base = $50.00" },
        { "amount" => 15.0,  "description_line" => "- $100 * 15% = $15.00 surplus revenue share for Project Lead" },
      ],
      "Commission" => [
        { "amount" => 25.0,  "description_line" => "- $500 * 5% = $25.00 commission" },
      ],
    }
    total = 100.0 + 80.0 + 15.0 + 50.0 + 15.0 + 25.0
    cp = build_cp(blueprint: blueprint, amount: total, qbo_accounts: @all_specific_accounts)

    lines = ContributorPayoutQboBillLines.new(cp, @all_specific_accounts).call

    assert_equal 6, lines.length

    by_account_name = lines.index_by { |l| l[:account].name }
    assert_equal 100.0, by_account_name[@ic_account.name][:amount]
    assert_equal 80.0,  by_account_name[@al_base_account.name][:amount]
    assert_equal 15.0,  by_account_name[@al_surplus_account.name][:amount]
    assert_equal 50.0,  by_account_name[@pl_base_account.name][:amount]
    assert_equal 15.0,  by_account_name[@pl_surplus_account.name][:amount]
    assert_equal 25.0,  by_account_name[@commission_account.name][:amount]

    # Each description starts with a "# <Role Label>" header.
    assert by_account_name[@ic_account.name][:description].start_with?("# Individual Contributor")
    assert by_account_name[@al_base_account.name][:description].start_with?("# Account Lead\n")
    assert by_account_name[@al_surplus_account.name][:description].start_with?("# Account Lead Surplus")
    assert by_account_name[@pl_base_account.name][:description].start_with?("# Project Lead\n")
    assert by_account_name[@pl_surplus_account.name][:description].start_with?("# Project Lead Surplus")
    assert by_account_name[@commission_account.name][:description].start_with?("# Commission")

    # Sum equals cp.amount.
    assert_equal total.round(2), lines.sum { |l| l[:amount] }.round(2)
  end

  test "zero-amount bucket is skipped" do
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 100.0, "description_line" => "- 10 hrs * $10 p/h = $100.00" },
      ],
      "AccountLead" => [
        { "amount" => 80.0, "description_line" => "- 8% base = $80.00" },
        { "amount" => 15.0, "description_line" => "- 15% surplus revenue share for AL" },
      ],
      "ProjectLead" => [
        { "amount" => 50.0, "description_line" => "- 5% base = $50.00" },
        { "amount" => 15.0, "description_line" => "- 15% surplus revenue share for PL" },
      ],
      "Commission" => [], # empty bucket → skipped
    }
    total = 100.0 + 80.0 + 15.0 + 50.0 + 15.0
    cp = build_cp(blueprint: blueprint, amount: total, qbo_accounts: @all_specific_accounts)

    lines = ContributorPayoutQboBillLines.new(cp, @all_specific_accounts).call

    assert_equal 5, lines.length
    assert_nil lines.find { |l| l[:account].name == @commission_account.name }
  end

  test "AL bucket splits into base and surplus lines via description_line discriminator" do
    blueprint = {
      "AccountLead" => [
        { "amount" => 80.0, "description_line" => "- 8% of working amount = $80.00" },
        { "amount" => 12.0, "description_line" => "- 15% of $80.00 surplus revenue share to AL" },
      ],
    }
    cp = build_cp(blueprint: blueprint, amount: 92.0, qbo_accounts: @all_specific_accounts)

    lines = ContributorPayoutQboBillLines.new(cp, @all_specific_accounts).call

    assert_equal 2, lines.length
    by_account = lines.index_by { |l| l[:account].name }
    assert_equal 80.0, by_account[@al_base_account.name][:amount]
    assert_equal 12.0, by_account[@al_surplus_account.name][:amount]
  end

  test "PL bucket splits into base and surplus lines via description_line discriminator" do
    blueprint = {
      "ProjectLead" => [
        { "amount" => 50.0, "description_line" => "- 5% of working amount = $50.00" },
        { "amount" => 9.0,  "description_line" => "- 15% of $60.00 surplus revenue share to PL" },
      ],
    }
    cp = build_cp(blueprint: blueprint, amount: 59.0, qbo_accounts: @all_specific_accounts)

    lines = ContributorPayoutQboBillLines.new(cp, @all_specific_accounts).call

    assert_equal 2, lines.length
    by_account = lines.index_by { |l| l[:account].name }
    assert_equal 50.0, by_account[@pl_base_account.name][:amount]
    assert_equal 9.0,  by_account[@pl_surplus_account.name][:amount]
  end

  test "specific account missing in qbo_accounts: that line falls back to default; others keep their specific accounts" do
    # Omit the AL surplus account from the qbo_accounts list.
    accounts_missing_al_surplus = @all_specific_accounts - [@al_surplus_account]

    blueprint = {
      "IndividualContributor" => [
        { "amount" => 100.0, "description_line" => "- 10 hrs * $10 = $100.00" },
      ],
      "AccountLead" => [
        { "amount" => 80.0, "description_line" => "- 8% base = $80.00" },
        { "amount" => 15.0, "description_line" => "- 15% surplus revenue share" },
      ],
    }
    cp = build_cp(blueprint: blueprint, amount: 195.0, qbo_accounts: accounts_missing_al_surplus)

    lines = ContributorPayoutQboBillLines.new(cp, accounts_missing_al_surplus).call

    assert_equal 3, lines.length
    by_amount = lines.index_by { |l| l[:amount] }

    assert_equal @ic_account.name,      by_amount[100.0][:account].name, "IC line should keep its specific account"
    assert_equal @al_base_account.name, by_amount[80.0][:account].name,  "AL base line should keep its specific account"
    assert_equal @default_account.name, by_amount[15.0][:account].name,  "AL surplus line should fall back to default"
  end

  test "not in_sync? returns a single line at the default account" do
    blueprint = {
      "IndividualContributor" => [{ "amount" => 80.0, "description_line" => "- partial" }],
    }
    cp = build_cp(blueprint: blueprint, amount: 100.0, in_sync: false, qbo_accounts: @all_specific_accounts)

    lines = ContributorPayoutQboBillLines.new(cp, @all_specific_accounts).call

    assert_equal 1, lines.length
    assert_equal 100.0, lines.first[:amount]
    assert_equal @default_account, lines.first[:account]
    assert_equal cp.bill_description, lines.first[:description]
  end

  test "drift safety: bucket sums totaling something other than cp.amount collapses to single line and logs WARN" do
    # `in_sync?` is stubbed true so we reach the drift-safety check after building.
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 60.0, "description_line" => "- six hours" },
      ],
      "AccountLead" => [
        { "amount" => 45.0, "description_line" => "- 8% base" },
      ],
    }
    # cp.amount is 100 but blueprint sums to 105 → drift, collapse.
    cp = build_cp(blueprint: blueprint, amount: 100.0, qbo_accounts: @all_specific_accounts)

    Rails.logger.expects(:warn).at_least_once

    lines = ContributorPayoutQboBillLines.new(cp, @all_specific_accounts).call

    assert_equal 1, lines.length
    assert_equal 100.0, lines.first[:amount]
    assert_equal @default_account, lines.first[:account]
    assert_equal cp.bill_description, lines.first[:description]
  end

  test "studio-less contributor: all lines fall back to default account" do
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 100.0, "description_line" => "- ten hours" },
      ],
      "AccountLead" => [
        { "amount" => 80.0, "description_line" => "- 8% base" },
        { "amount" => 15.0, "description_line" => "- 15% surplus revenue share" },
      ],
      "Commission" => [
        { "amount" => 25.0, "description_line" => "- 5% commission" },
      ],
    }
    # studio_label nil → qbo_subcontractors_categories returns nil → all lines fall back.
    cp = build_cp(blueprint: blueprint, amount: 220.0, studio_label: nil, qbo_accounts: @all_specific_accounts)

    lines = ContributorPayoutQboBillLines.new(cp, @all_specific_accounts).call

    assert_equal 4, lines.length
    lines.each do |line|
      assert_equal @default_account, line[:account], "Expected #{line[:description].lines.first} to fall back to default"
    end
  end

  test "studio with empty qbo_subcontractors_categories: all lines fall back to default account" do
    blueprint = {
      "IndividualContributor" => [
        { "amount" => 100.0, "description_line" => "- ten hours" },
      ],
    }
    cp = build_cp(blueprint: blueprint, amount: 100.0, qbo_accounts: @all_specific_accounts)
    # Override the studio's categories to be an empty array (first → nil → fall back).
    cp.contributor.forecast_person.studio.stubs(:qbo_subcontractors_categories).returns([])

    lines = ContributorPayoutQboBillLines.new(cp, @all_specific_accounts).call

    assert_equal 1, lines.length
    assert_equal @default_account, lines.first[:account]
  end
end
