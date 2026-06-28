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

  test "PayStub routes to a single :salaries line" do
    item = line_item_stub(PayStub, amount: 1000.0, description: "stub-url")
    lines = router_for_routing(item).concept_lines
    assert_equal [{ amount: 1000.0, description: "stub-url", concept: :salaries }], lines
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
end
