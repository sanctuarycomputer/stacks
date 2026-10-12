require "test_helper"

class Mso::ManagementFeeInvoicesTrackersTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  def setup
    @qbo_account = garden3d_qbo_account
    @pass = garden3d_pass(Date.new(2095, 6, 1))
    @sanctuary = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [950_001])
    @index = make_payer(Enterprise::INDEX_SPACE_NAME, customer_id: "5", forecast_ids: [950_002])
  end

  def teardown
    clear_enterprise_memos
  end

  def trackers_on(pass)
    InvoiceTracker.where(invoice_pass_id: pass.id).order(:id)
  end

  test "it refuses Sanctuary's pass" do
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 6, 1), enterprise: enterprises(:sanctuary), data: {})

    error = assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: pass)
    end

    assert_match(/Sanctuary Computer Inc/, error.message)
    assert_equal 0, trackers_on(pass).count
  end

  test "it refuses any other enterprise's pass" do
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 6, 1), enterprise: enterprises(:one), data: {})

    assert_raises(Mso::ManagementFeeInvoices::WrongPass) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: pass)
    end
  end

  test "it makes one blueprint-less tracker per payer on garden3d's QuickBooks account" do
    trackers = Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    assert_equal [950_001, 950_002].sort, trackers.map(&:forecast_client_id).sort
    assert_equal trackers.map(&:id).sort, trackers_on(@pass).pluck(:id)
    trackers.each do |tracker|
      assert_equal @qbo_account.id, tracker.qbo_account_id
      assert_nil tracker.blueprint
      assert_nil tracker.qbo_invoice_id
      assert tracker.management_fee?
    end
  end

  test "running it twice changes nothing" do
    first = Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    assert_no_difference -> { InvoiceTracker.count } do
      second = Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: InvoicePass.find(@pass.id))
      assert_equal first.map(&:id), second.map(&:id)
    end
  end

  # Runs `rival` once, after ensure_trackers! has looked for a tracker and
  # found none but before it inserts its own: what a second request (a double
  # click, or the click racing the nightly run) does to the first.
  def with_rival_insert(rival)
    service = Mso::ManagementFeeInvoices.singleton_class
    original = service.instance_method(:create_or_find_tracker!)
    raced = false
    service.send(:define_method, :create_or_find_tracker!) do |*args|
      unless raced
        raced = true
        rival.call
      end
      original.bind(self).call(*args)
    end
    yield
  ensure
    service.send(:define_method, :create_or_find_tracker!, original)
    service.send(:private, :create_or_find_tracker!)
  end

  test "losing a first-time race to another request uses its tracker instead of raising" do
    rival = nil

    trackers = with_rival_insert(-> { rival = fee_tracker(@pass, @sanctuary) }) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)
    end

    assert_includes trackers.map(&:id), rival.id
    assert_equal [950_001, 950_002], trackers.map(&:forecast_client_id).sort
    # The refused insert did not poison the transaction: the other payer's
    # tracker was still created, and there is exactly one per payer.
    assert_equal trackers.map(&:id).sort, trackers_on(@pass).pluck(:id)
    assert_equal 2, trackers_on(@pass).count
  end

  test "it never calls QuickBooks" do
    QboAccount.any_instance.expects(:make_and_refresh_qbo_access_token).never
    QboAccount.any_instance.expects(:fetch_all_customers).never
    Quickbooks::Service::Invoice.any_instance.expects(:create).never
    Quickbooks::Service::Customer.any_instance.expects(:create).never

    Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)
  end

  test "an enterprise that is not flagged gets no tracker" do
    bystander = Enterprise.create!(name: "Bystander #{SecureRandom.hex(3)}")
    ForecastClient.create!(forecast_id: 950_003, name: "Bystander internal")
    EnterpriseForecastClient.create!(enterprise: bystander, forecast_client_id: 950_003)

    Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    assert_equal 0, trackers_on(@pass).where(forecast_client_id: 950_003).count
  end

  test "a payer with no internal client raises and leaves no trackers behind" do
    orphan = Enterprise.create!(name: "No Client #{SecureRandom.hex(3)}", management_fee_payer: true)

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)
    end

    assert_match(/#{Regexp.escape(orphan.name)}/, error.message)
    assert_equal 0, trackers_on(@pass).count
  end

  test "a payer with several internal clients gets one tracker, on the lowest forecast id" do
    make_payer("Many Clients #{SecureRandom.hex(3)}", forecast_ids: [950_030, 950_010, 950_020])

    Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    on_many = trackers_on(@pass).where(forecast_client_id: [950_010, 950_020, 950_030])
    assert_equal [950_010], on_many.pluck(:forecast_client_id)
  end

  test "a tracker already on another of the payer's clients is reused" do
    many = make_payer("Remapped #{SecureRandom.hex(3)}", forecast_ids: [950_050])
    existing = fee_tracker(@pass, many)
    ForecastClient.create!(forecast_id: 950_040, name: "Remapped, lower id")
    EnterpriseForecastClient.create!(enterprise: many, forecast_client_id: 950_040)

    trackers = Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)

    assert_includes trackers.map(&:id), existing.id
    assert_equal 0, trackers_on(@pass).where(forecast_client_id: 950_040).count
  end

  test "it raises when garden3d has no QuickBooks account" do
    QboAccount.where(enterprise_id: garden3d.id).delete_all

    error = assert_raises(Mso::ManagementFeeInvoices::Misconfigured) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)
    end

    assert_match(/no connected QboAccount/, error.message)
  end

  test "it raises when no enterprise is flagged as a payer" do
    Enterprise.update_all(management_fee_payer: false)

    assert_raises(Mso::ManagementFeeInvoices::Misconfigured) do
      Mso::ManagementFeeInvoices.ensure_trackers!(invoice_pass: @pass)
    end
  end
end
