require "test_helper"

class Qbo::BillAccountResolverTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "ResolverTest-#{SecureRandom.hex(2)}")
    @qa = QboAccount.create!(enterprise: @enterprise, client_id: "x", client_secret: "y", realm_id: "realm-#{SecureRandom.hex(4)}")

    @default_acct = QboChartAccount.create!(qbo_account: @qa, qbo_id: "100", name: "Contractors - Client Services", data: {})
    @contributor_acct = QboChartAccount.create!(qbo_account: @qa, qbo_id: "200", name: "Contractors - Special", data: {})
    @tracker_acct = QboChartAccount.create!(qbo_account: @qa, qbo_id: "300", name: "Contractors - Marketing Services", data: {})

    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "r#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @tracker = ProjectTracker.new(name: "RT-#{SecureRandom.hex(2)}")
    @tracker.save!(validate: false)

    @resolver = Qbo::BillAccountResolver.new(@enterprise)
  end

  def map!(key, qbo_id, contributor: nil, project_tracker: nil)
    QboBillAccountMapping.create!(
      enterprise: @enterprise, line_item_key: key,
      contributor: contributor, project_tracker: project_tracker,
      qbo_chart_account_qbo_id: qbo_id,
    )
  end

  test "falls through to the entity default when no override matches" do
    map!("trueup", "100")
    account = @resolver.account_for("trueup", contributor: @contributor)
    assert_equal @default_acct, account
  end

  test "contributor mapping beats entity default" do
    map!("trueup", "100")
    map!("trueup", "200", contributor: @contributor)
    assert_equal @contributor_acct, @resolver.account_for("trueup", contributor: @contributor)
  end

  test "project tracker mapping beats contributor mapping" do
    map!("payout_individual_contributor", "100")
    map!("payout_individual_contributor", "200", contributor: @contributor)
    map!("payout_individual_contributor", "300", project_tracker: @tracker)
    account = @resolver.account_for("payout_individual_contributor", contributor: @contributor, project_tracker: @tracker)
    assert_equal @tracker_acct, account
  end

  test "ignores tracker mappings when no tracker is given" do
    map!("payout_individual_contributor", "300", project_tracker: @tracker)
    map!("payout_individual_contributor", "100")
    assert_equal @default_acct, @resolver.account_for("payout_individual_contributor", contributor: @contributor)
  end

  test "another contributor's mapping does not apply" do
    map!("trueup", "100")
    map!("trueup", "200", contributor: @contributor)

    other_fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "o#{SecureRandom.hex(2)}@x.com", data: {})
    other_contributor = Contributor.create!(forecast_person: other_fp)

    assert_equal @default_acct, @resolver.account_for("trueup", contributor: other_contributor)
  end

  test "another tracker's mapping does not apply" do
    map!("trueup", "100")
    map!("trueup", "300", project_tracker: @tracker)

    other_tracker = ProjectTracker.new(name: "OT-#{SecureRandom.hex(2)}")
    other_tracker.save!(validate: false)

    assert_equal @default_acct, @resolver.account_for("trueup", contributor: @contributor, project_tracker: other_tracker)
  end

  test "raises UnmappedLineItemError when the mapped chart account is missing from the mirror" do
    map!("trueup", "100")
    @default_acct.delete
    err = assert_raises(Qbo::UnmappedLineItemError) { @resolver.account_for("trueup", contributor: @contributor) }
    assert_match(/missing/, err.message)
  end

  test "raises UnmappedLineItemError naming the chain when nothing matches" do
    err = assert_raises(Qbo::UnmappedLineItemError) do
      @resolver.account_for("pay_stub", contributor: @contributor, project_tracker: @tracker)
    end
    assert_match(/no QBO account mapping for pay_stub/, err.message)
    assert_match(/ProjectTracker##{@tracker.id}/, err.message)
    assert_match(/Contributor##{@contributor.id}/, err.message)
    assert_match(/entity default/, err.message)
  end

  test "raises UnmappedLineItemError when the mapped chart account has been deactivated" do
    map!("trueup", "100")
    @default_acct.update!(active: false)
    err = assert_raises(Qbo::UnmappedLineItemError) { @resolver.account_for("trueup", contributor: @contributor) }
    assert_match(/inactive/, err.message)
  end

  test "raises UnmappedLineItemError when the enterprise has no qbo_account" do
    bare = Enterprise.find_or_create_by!(name: "Bare-#{SecureRandom.hex(2)}")
    err = assert_raises(Qbo::UnmappedLineItemError) do
      Qbo::BillAccountResolver.new(bare).account_for("trueup", contributor: @contributor)
    end
    assert_match(/no connected QboAccount/, err.message)
  end

  test "raises ArgumentError for unknown line_item_key" do
    assert_raises(ArgumentError) { @resolver.account_for("bogus", contributor: @contributor) }
  end
end
