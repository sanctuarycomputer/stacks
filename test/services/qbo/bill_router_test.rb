require "test_helper"
require "ostruct"

class Qbo::BillRouterTest < ActiveSupport::TestCase
  # A router whose context (gl map, studio, accounts) is fully stubbed so these
  # tests never touch the DB or the real CONCEPT_GL_BY_ENTERPRISE constant.
  def router_with(accounts:, gl_map:, studio: nil, item: nil)
    r = Qbo::BillRouter.new(item || Object.new, accounts_cache: Qbo::AccountsCache.new)
    r.stubs(:accounts).returns(accounts)
    r.stubs(:enterprise_gl_map).returns(gl_map)
    r.stubs(:studio).returns(studio)
    r.stubs(:enterprise).returns(OpenStruct.new(name: "Test Enterprise"))
    r
  end

  def acct(num, id)
    OpenStruct.new(acct_num: num, id: id, name: "Acct #{num}")
  end

  test "resolve finds the account whose acct_num matches the concept's GL code" do
    gl_map = { bonuses: "5710", subcontractor_default: "5000" }
    accounts = [acct("5710", 5710), acct("5000", 5000)]
    r = router_with(accounts: accounts, gl_map: gl_map)
    assert_equal 5710, r.resolve(:bonuses).id
  end

  test "resolve falls back to subcontractor_default for a missing fallbackable concept" do
    gl_map = { bonuses: "5710", subcontractor_default: "5000" }
    accounts = [acct("5000", 5000)] # 5710 absent
    r = router_with(accounts: accounts, gl_map: gl_map)
    assert_equal 5000, r.resolve(:bonuses).id, "missing bonuses falls back to default"
  end

  test "resolve resolves :subcontractor via the studio's GL code" do
    studio = OpenStruct.new(name: "Bakery")
    gl_map = { subcontractor_default: "5000", subcontractor_by_studio: { "Bakery" => "5010" } }
    accounts = [acct("5000", 5000), acct("5010", 5010)]
    r = router_with(accounts: accounts, gl_map: gl_map, studio: studio)
    assert_equal 5010, r.resolve(:subcontractor).id
  end

  test "resolve :subcontractor falls back to default when studio has no GL entry" do
    studio = OpenStruct.new(name: "Unknown Studio")
    gl_map = { subcontractor_default: "5000", subcontractor_by_studio: {} }
    accounts = [acct("5000", 5000)]
    r = router_with(accounts: accounts, gl_map: gl_map, studio: studio)
    assert_equal 5000, r.resolve(:subcontractor).id
  end

  test "resolve raises when subcontractor_default itself is missing" do
    gl_map = { subcontractor_default: "5000" }
    accounts = [] # nothing
    r = router_with(accounts: accounts, gl_map: gl_map)
    err = assert_raises(RuntimeError) { r.resolve(:subcontractor_default) }
    assert_match(/subcontractor_default/, err.message)
  end

  test "resolve raises when a non-fallbackable concept (salaries) is missing" do
    gl_map = { salaries: "1500", subcontractor_default: "5000" }
    accounts = [acct("5000", 5000)] # 1500 absent
    r = router_with(accounts: accounts, gl_map: gl_map)
    err = assert_raises(RuntimeError) { r.resolve(:salaries) }
    assert_match(/salaries/, err.message)
    assert_match(/1500/, err.message)
  end

  test "resolve raises when profit_share_liability is missing (no silent fallback)" do
    gl_map = { profit_share_liability: "2340", subcontractor_default: "5000" }
    accounts = [acct("5000", 5000)] # 2340 absent
    r = router_with(accounts: accounts, gl_map: gl_map)
    assert_raises(RuntimeError) { r.resolve(:profit_share_liability) }
  end

  # --- routing: single-line items ---

  def line_item_stub(klass, amount:, description:)
    m = mock(klass.name)
    m.stubs(:is_a?).returns(false)
    m.stubs(:is_a?).with(klass).returns(true)
    m.stubs(:amount).returns(amount)
    m.stubs(:bill_description).returns(description)
    m
  end

  def router_for_routing(item)
    Qbo::BillRouter.new(item, accounts_cache: Qbo::AccountsCache.new)
  end

  test "PayStub: empty blueprint lines yields []" do
    item = mock("PayStub")
    item.stubs(:is_a?).returns(false)
    item.stubs(:is_a?).with(PayStub).returns(true)
    item.stubs(:blueprint).returns({ "lines" => [] })
    lines = router_for_routing(item).concept_lines
    assert_equal [], lines
  end

  test "PayStub: multi-project blueprint produces one :salaries line per forecast_project" do
    item = mock("PayStub")
    item.stubs(:is_a?).returns(false)
    item.stubs(:is_a?).with(PayStub).returns(true)
    item.stubs(:blueprint).returns({
      "lines" => [
        { "forecast_project" => 101, "hours" => 8.0,  "amount" => 800.0 },
        { "forecast_project" => 101, "hours" => 2.0,  "amount" => 200.0 },
        { "forecast_project" => 202, "hours" => 4.0,  "amount" => 400.0 },
      ]
    })

    fp101 = OpenStruct.new(forecast_id: 101, display_name: "Alpha Project")
    fp202 = OpenStruct.new(forecast_id: 202, display_name: "Beta Project")
    projects_by_id = { 101 => fp101, 202 => fp202 }

    rel = mock("relation")
    rel.stubs(:index_by).returns(projects_by_id)
    ForecastProject.stubs(:where).with(forecast_id: [101, 202]).returns(rel)

    lines = router_for_routing(item).concept_lines

    assert_equal 2, lines.size
    assert lines.all? { |l| l[:concept] == :salaries }, "all lines should be :salaries"

    alpha = lines.find { |l| l[:description].include?("Alpha Project") }
    beta  = lines.find { |l| l[:description].include?("Beta Project") }

    assert_equal 1000.0, alpha[:amount]
    assert_equal "Alpha Project — 10.0h", alpha[:description]

    assert_equal 400.0, beta[:amount]
    assert_equal "Beta Project — 4.0h", beta[:description]
  end

  test "ProfitShare routes to a single :profit_share_liability line" do
    item = line_item_stub(ProfitShare, amount: 250.0, description: "ps-url")
    lines = router_for_routing(item).concept_lines
    assert_equal [{ amount: 250.0, description: "ps-url", concept: :profit_share_liability }], lines
  end

  test "Trueup routes to a single :subcontractor line" do
    item = line_item_stub(Trueup, amount: 42.0, description: "tu-url")
    lines = router_for_routing(item).concept_lines
    assert_equal [{ amount: 42.0, description: "tu-url", concept: :subcontractor }], lines
  end

  test "ContributorAdjustment routes to a single :subcontractor line" do
    item = line_item_stub(ContributorAdjustment, amount: 15.0, description: "ca-url")
    lines = router_for_routing(item).concept_lines
    assert_equal [{ amount: 15.0, description: "ca-url", concept: :subcontractor }], lines
  end

  # --- routing: ContributorPayout multi-line ---

  # cp mock with the payout-routing surface; base_concept is stubbed on the
  # router so these tests are independent of the internal-client logic (Task 5).
  def make_cp(blueprint:, amount:, in_sync: true)
    cp = mock("contributor_payout")
    cp.stubs(:is_a?).returns(false)
    cp.stubs(:is_a?).with(ContributorPayout).returns(true)
    cp.stubs(:in_sync?).returns(in_sync)
    cp.stubs(:blueprint).returns(blueprint)
    cp.stubs(:amount).returns(amount)
    cp.stubs(:bill_description).returns("https://example.com/cp/42")
    cp.stubs(:id).returns(42)
    cp
  end

  def payout_router(cp, base_concept: :subcontractor)
    r = Qbo::BillRouter.new(cp, accounts_cache: Qbo::AccountsCache.new)
    r.stubs(:base_concept).returns(base_concept)
    r
  end

  def all_buckets_blueprint
    {
      "IndividualContributor" => [{ "amount" => 100.0, "description_line" => "- IC line" }],
      "AccountLead"           => [
        { "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8 base" },
        { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
      "ProjectLead"           => [
        { "amount" => 5.0, "description_line" => "- 100hrs * 5% = $5 base" },
        { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
      ],
      "Commission"            => [{ "amount" => 10.0, "description_line" => "- 5% of $200 = $10" }],
    }
  end

  test "multi-line happy path: 6 buckets with correct concepts" do
    cp = make_cp(blueprint: all_buckets_blueprint, amount: 129.0)
    lines = payout_router(cp).concept_lines

    assert_equal 6, lines.size
    by_concept = lines.group_by { |l| l[:concept] }
    assert_equal 1, by_concept[:commission].size
    assert_equal 10.0, by_concept[:commission].first[:amount]
    assert_equal 2, by_concept[:bonuses].size, "AL + PL surplus both -> :bonuses"
    assert_equal 3, by_concept[:subcontractor].size, "IC + AL base + PL base -> base concept"
    assert_equal 129.0, lines.sum { |l| l[:amount] }.round(2)
  end

  test "Account Lead split into base/surplus by 'surplus revenue' marker" do
    blueprint = { "AccountLead" => [
      { "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8" },
      { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
    ] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 11.0)).concept_lines

    base    = lines.find { |l| l[:description].include?("Account Lead\n") }
    surplus = lines.find { |l| l[:description].include?("Account Lead Surplus") }
    assert_equal [8.0, :subcontractor], [base[:amount], base[:concept]]
    assert_equal [3.0, :bonuses], [surplus[:amount], surplus[:concept]]
  end

  test "Project Lead split into base/surplus by marker" do
    blueprint = { "ProjectLead" => [
      { "amount" => 5.0, "description_line" => "- 100hrs * 5% = $5" },
      { "amount" => 3.0, "description_line" => "- $20 surplus revenue * 15% = $3" },
    ] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 8.0)).concept_lines

    surplus = lines.find { |l| l[:description].include?("Project Lead Surplus") }
    assert_equal [3.0, :bonuses], [surplus[:amount], surplus[:concept]]
  end

  test "zero-amount bucket is skipped" do
    blueprint = {
      "IndividualContributor" => [{ "amount" => 100.0, "description_line" => "-" }],
      "Commission"            => [],
    }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 100.0)).concept_lines
    assert_equal 1, lines.size
    assert_equal 100.0, lines.first[:amount]
  end

  test "not in_sync? -> single collapsed line at base concept and cp.amount" do
    blueprint = { "IndividualContributor" => [{ "amount" => 200.0, "description_line" => "-" }] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 100.0, in_sync: false)).concept_lines
    assert_equal 1, lines.size
    assert_equal 100.0, lines.first[:amount]
    assert_equal "https://example.com/cp/42", lines.first[:description]
    assert_equal :subcontractor, lines.first[:concept]
  end

  test "per-bucket drift from cp.amount -> collapse + WARN" do
    blueprint = { "IndividualContributor" => [{ "amount" => 105.0, "description_line" => "-" }] }
    Rails.logger.expects(:warn).at_least_once
    lines = payout_router(make_cp(blueprint: blueprint, amount: 100.0)).concept_lines
    assert_equal 1, lines.size
    assert_equal 100.0, lines.first[:amount]
  end

  test "every bucket empty -> collapse to single line" do
    blueprint = { "IndividualContributor" => [] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 0.0)).concept_lines
    assert_equal 1, lines.size
    assert_equal 0.0, lines.first[:amount]
  end

  test "structured AccountLeadSurplus key routes to :bonuses without marker" do
    blueprint = {
      "AccountLead"        => [{ "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8" }],
      "AccountLeadSurplus" => [{ "amount" => 3.0, "description_line" => "- marker-free copy" }],
    }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 11.0)).concept_lines
    surplus = lines.find { |l| l[:description].include?("Account Lead Surplus") }
    assert_equal [3.0, :bonuses], [surplus[:amount], surplus[:concept]]
  end

  test "structured ProjectLeadSurplus key routes to :bonuses" do
    blueprint = {
      "ProjectLead"        => [{ "amount" => 5.0, "description_line" => "- 100hrs * 5% = $5" }],
      "ProjectLeadSurplus" => [{ "amount" => 3.0, "description_line" => "- marker-free copy" }],
    }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 8.0)).concept_lines
    surplus = lines.find { |l| l[:description].include?("Project Lead Surplus") }
    assert_equal [3.0, :bonuses], [surplus[:amount], surplus[:concept]]
  end

  test "mixed structured + legacy AccountLead surplus entries are summed" do
    blueprint = {
      "AccountLead"        => [
        { "amount" => 8.0, "description_line" => "- 100hrs * 8% = $8 base" },
        { "amount" => 2.0, "description_line" => "- legacy surplus revenue share = $2" },
      ],
      "AccountLeadSurplus" => [{ "amount" => 3.0, "description_line" => "- marker-free copy" }],
    }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 13.0)).concept_lines
    surplus = lines.find { |l| l[:description].include?("Account Lead Surplus") }
    assert_equal 5.0, surplus[:amount], "structured $3 + parsed legacy $2"
    base = lines.find { |l| l[:description].include?("Account Lead\n") }
    assert_equal 8.0, base[:amount]
  end

  test "description format: role header + entry lines + admin URL" do
    blueprint = { "Commission" => [
      { "amount" => 10.0, "description_line" => "- 5% of $200 = $10" },
      { "amount" => 5.0,  "description_line" => "- 5% of $100 = $5" },
    ] }
    lines = payout_router(make_cp(blueprint: blueprint, amount: 15.0)).concept_lines
    desc = lines.first[:description]
    assert_match(/\A# Commission\n/, desc)
    assert_includes desc, "- 5% of $200 = $10"
    assert_includes desc, "- 5% of $100 = $5"
    assert_includes desc, "https://example.com/cp/42"
  end

  # --- base_concept (internal-client marketing override) ---

  def base_concept_router(internal:, studio:)
    r = Qbo::BillRouter.new(Object.new, accounts_cache: Qbo::AccountsCache.new)
    r.stubs(:internal_client?).returns(internal)
    r.stubs(:studio).returns(studio)
    r
  end

  test "base_concept is :subcontractor for a non-internal client" do
    r = base_concept_router(internal: false, studio: nil)
    assert_equal :subcontractor, r.send(:base_concept)
  end

  test "base_concept is :marketing for an internal client with no studio" do
    r = base_concept_router(internal: true, studio: nil)
    assert_equal :marketing, r.send(:base_concept)
  end

  test "base_concept is :marketing for an internal client on a client-services studio" do
    studio = OpenStruct.new(name: "CS", client_services?: true)
    r = base_concept_router(internal: true, studio: studio)
    assert_equal :marketing, r.send(:base_concept)
  end

  test "base_concept stays :subcontractor for an internal client on a NON-client-services studio" do
    studio = OpenStruct.new(name: "Internal Studio", client_services?: false)
    r = base_concept_router(internal: true, studio: studio)
    assert_equal :subcontractor, r.send(:base_concept)
  end

  # --- #lines joins routing to resolution ---

  test "#lines resolves each concept line to a concrete account" do
    item = line_item_stub(Trueup, amount: 42.0, description: "tu-url")
    r = Qbo::BillRouter.new(item, accounts_cache: Qbo::AccountsCache.new)
    r.stubs(:studio).returns(nil)
    default = acct("5000", 5000)
    r.stubs(:accounts).returns([default])
    r.stubs(:enterprise).returns(OpenStruct.new(name: "Test Enterprise"))
    r.stubs(:enterprise_gl_map).returns({ subcontractor_default: "5000" })

    lines = r.lines
    assert_equal 1, lines.size
    assert_equal 42.0, lines.first[:amount]
    assert_equal "tu-url", lines.first[:description]
    assert_same default, lines.first[:account]
  end

  test "two routers sharing one cache fetch the chart of accounts only once" do
    accounts = [acct("5000", 5000)]
    qa = mock("qa"); qa.stubs(:id).returns(99)
    qa.expects(:fetch_all_accounts).once.returns(accounts)

    cache = Qbo::AccountsCache.new
    item1 = line_item_stub(Trueup, amount: 1.0, description: "u1")
    item2 = line_item_stub(Trueup, amount: 2.0, description: "u2")

    [item1, item2].each do |it|
      r = Qbo::BillRouter.new(it, accounts_cache: cache)
      r.stubs(:studio).returns(nil)
      r.stubs(:qbo_account).returns(qa)
      r.stubs(:enterprise).returns(OpenStruct.new(name: "Test Enterprise"))
      r.stubs(:enterprise_gl_map).returns({ subcontractor_default: "5000" })
      r.lines
    end
  end

  # --- Finding 2: double-miss fallback error message ---

  test "resolve raises with subcontractor_default in message when both fallbackable concept AND default are missing" do
    gl_map = { bonuses: "5710", subcontractor_default: "5000" }
    accounts = [] # both 5710 and 5000 absent
    r = router_with(accounts: accounts, gl_map: gl_map)
    err = assert_raises(RuntimeError) { r.resolve(:bonuses) }
    assert_match(/bonuses/, err.message)
    assert_match(/5710/, err.message)
    assert_match(/subcontractor_default/, err.message)
    assert_match(/5000/, err.message)
  end

  # --- Finding 3: CONCEPT_GL_BY_ENTERPRISE constant integrity ---

  test "CONCEPT_GL_BY_ENTERPRISE[:sanctuary] has correct known GL codes" do
    map = Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[:sanctuary]
    assert_equal "5710", map[:bonuses]
    assert_equal "6120", map[:commission]
    assert_equal "2340", map[:profit_share_liability]
  end

  # Guards the multi-enterprise regression: every enterprise that syncs bills
  # must be routable. ENTERPRISE_KEY_BY_NAME must cover all four bill-syncing
  # enterprise names, each pointing at a complete CONCEPT_GL_BY_ENTERPRISE entry.
  REQUIRED_CONCEPT_KEYS = %i[
    subcontractor_default marketing salaries
    bonuses commission profit_share_liability subcontractor_by_studio
  ].freeze

  test "every bill-syncing enterprise name maps to a complete GL entry" do
    expected_names = [
      Enterprise::SANCTUARY_NAME,
      Enterprise::INDEX_SPACE_NAME,
      Enterprise::GARDEN3D_NAME,
      Enterprise::USB_CLUB_NAME,
    ]
    assert_equal expected_names.sort, Qbo::BillRouter::ENTERPRISE_KEY_BY_NAME.keys.sort

    Qbo::BillRouter::ENTERPRISE_KEY_BY_NAME.each_value do |key|
      entry = Qbo::BillRouter::CONCEPT_GL_BY_ENTERPRISE[key]
      assert entry, "no CONCEPT_GL_BY_ENTERPRISE entry for #{key.inspect}"
      REQUIRED_CONCEPT_KEYS.each do |concept|
        assert entry.key?(concept), "#{key.inspect} entry missing #{concept.inspect}"
      end
    end
  end
end
