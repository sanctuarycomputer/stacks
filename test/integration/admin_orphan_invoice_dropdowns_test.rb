require "test_helper"

# garden3d's management fee invoices are intercompany. They belong on a
# management fee tracker and nowhere else, so the other forms that offer
# QuickBooks invoices to attach must not offer them.
class AdminOrphanInvoiceDropdownsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ManagementFeeFixtures

  setup do
    @admin = AdminUser.create!(email: "dropdown-admin@sanctuary.computer", password: "password12345", roles: ["admin"])
    @qbo_account = garden3d_qbo_account
    @sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    @payer = make_payer(Enterprise::SANCTUARY_NAME, customer_id: "2", forecast_ids: [986_001])

    # Hand-made and attached to nothing: billed to a payer's stored customer id.
    @fee = mirror!(@qbo_account, "7001", customer_id: "2")
    # garden3d's, but to someone who is not a payer.
    @garden3d_other = mirror!(@qbo_account, "7002", customer_id: "9")
    # Sanctuary's own invoice to a customer who happens to share the id value.
    @ordinary = mirror!(@sanctuary_qa, "7003", customer_id: "2")

    # Rendering a form must never read QuickBooks.
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
    sign_in @admin
  end

  teardown do
    clear_enterprise_memos
  end

  def mirror!(qbo_account, doc_number, customer_id:)
    QboInvoice.create!(qbo_account: qbo_account, qbo_id: "q-#{doc_number}", data: {
      "doc_number" => doc_number, "total" => "10.0", "balance" => "10.0", "email_status" => "NotSet",
      "txn_date" => "2094-09-30", "customer_ref" => { "name" => "Customer #{customer_id}", "value" => customer_id },
    })
  end

  def option_labels(select_css)
    css_select("#{select_css} option").map { |option| option.text.strip }
  end

  def labels_mentioning(labels, invoice)
    labels.select { |label| label.include?("##{invoice.read_attribute(:data)['doc_number']} ") }
  end

  # --- the project tracker's adhoc invoice select ------------------------------

  def project_tracker_with_adhoc_row
    pt = ProjectTracker.new(name: "Dropdown #{SecureRandom.hex(2)}")
    pt.save!(validate: false)
    pt.project_tracker_links.create!(name: "MSA", url: "https://x/msa", link_type: :msa)
    pt.project_tracker_links.create!(name: "SOW", url: "https://x/sow", link_type: :sow)
    # An existing row, so the form renders the select itself and not only the
    # template behind "Connect an Adhoc Invoice".
    attached = mirror!(@sanctuary_qa, "7004", customer_id: "9")
    AdhocInvoiceTracker.create!(project_tracker: pt, qbo_account: @sanctuary_qa, qbo_invoice_id: attached.qbo_id)
    pt
  end

  def adhoc_labels
    option_labels("select[name='project_tracker[adhoc_invoice_trackers_attributes][0][qbo_invoice_id]']")
  end

  test "the project tracker form does not offer a management fee invoice as an adhoc invoice" do
    get edit_admin_project_tracker_path(project_tracker_with_adhoc_row)

    assert_response :success
    labels = adhoc_labels
    assert_empty labels_mentioning(labels, @fee), "garden3d's fee invoice must not be offered"
    assert_equal 1, labels_mentioning(labels, @ordinary).size, "an ordinary orphan still is"
    assert_equal 1, labels_mentioning(labels, @garden3d_other).size, "so is a garden3d invoice to a non-payer"
  end

  test "before the migration has run the project tracker form offers every orphan and reads no new column" do
    columns_before_migration = Enterprise.column_names - %w[g3d_qbo_customer_id]
    Enterprise.stubs(:column_names).returns(columns_before_migration)

    get edit_admin_project_tracker_path(project_tracker_with_adhoc_row)

    assert_response :success
    labels = adhoc_labels
    assert_equal 1, labels_mentioning(labels, @fee).size
    assert_equal 1, labels_mentioning(labels, @ordinary).size
  end

  # --- the contributor adjustment's invoice select ------------------------------

  def ledger
    @ledger ||= begin
      person = ForecastPerson.create!(forecast_id: 986_010, email: "dropdown-payee@example.com", data: {})
      person.ensure_contributor_exists!
      Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: person.reload.contributor)
    end
  end

  def adjustment_labels
    option_labels("select#contributor_adjustment_qbo_invoice_id")
  end

  test "the contributor adjustment form does not offer a management fee invoice" do
    get new_admin_ledger_contributor_adjustment_path(ledger)

    assert_response :success
    labels = adjustment_labels
    assert_empty labels_mentioning(labels, @fee), "garden3d's fee invoice must not be offered"
    assert_equal 1, labels_mentioning(labels, @ordinary).size, "an ordinary invoice still is"
    assert_equal 1, labels_mentioning(labels, @garden3d_other).size, "so is a garden3d invoice to a non-payer"
  end

  test "the contributor adjustment edit form keeps the invoice it already points at selected" do
    adjustment = ContributorAdjustment.create!(ledger: ledger, amount: 10, effective_on: Date.new(2094, 9, 1),
                                               qbo_account: @sanctuary_qa, qbo_invoice_id: @ordinary.qbo_id)

    get edit_admin_ledger_contributor_adjustment_path(ledger, adjustment)

    assert_response :success
    assert_select "select#contributor_adjustment_qbo_invoice_id option[selected][value=?]",
                  "#{@sanctuary_qa.id}:#{@ordinary.qbo_id}", count: 1
    assert_empty labels_mentioning(adjustment_labels, @fee)
  end

  test "the contributor adjustment form does not offer an invoice attached to a management fee tracker" do
    # No stored customer id to recognise it by: the attachment alone marks it.
    # (This select lists every invoice, attached ones included.)
    @payer.update_columns(g3d_qbo_customer_id: nil)
    fee_tracker(garden3d_pass(Date.new(2094, 9, 1)), @payer).update!(qbo_invoice_id: @fee.qbo_id)

    get new_admin_ledger_contributor_adjustment_path(ledger)

    assert_response :success
    labels = adjustment_labels
    assert_empty labels_mentioning(labels, @fee)
    assert_equal 1, labels_mentioning(labels, @ordinary).size
  end

  test "before the migration has run the contributor adjustment form offers every invoice" do
    columns_before_migration = Enterprise.column_names - %w[g3d_qbo_customer_id]
    Enterprise.stubs(:column_names).returns(columns_before_migration)

    get new_admin_ledger_contributor_adjustment_path(ledger)

    assert_response :success
    assert_equal 1, labels_mentioning(adjustment_labels, @fee).size
  end
end
