require "test_helper"
require Rails.root.join("db/migrate/20261012000002_backfill_invoice_pass_enterprises.rb")

class BackfillInvoicePassEnterprisesTest < ActiveSupport::TestCase
  def setup
    # schema.rb already carries the post-migration NOT NULL constraint, so drop
    # it for the duration to simulate the pre-backfill state. Rolls back with
    # the fixture transaction. The schema cache must be cleared too, or the
    # migration's own column_not_null? check reads the stale `null: false`.
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE invoice_passes ALTER COLUMN enterprise_id DROP NOT NULL"
    )
    ActiveRecord::Base.connection.schema_cache.clear!
    InvoicePass.reset_column_information

    @sanctuary = enterprises(:sanctuary)
    @garden3d = enterprises(:garden3d)
    # Sanctuary already has two qbo_account fixtures; pin the one has_one picks.
    @sanctuary_qa = Enterprise.find(@sanctuary.id).qbo_account
    @garden3d_qa = QboAccount.create!(enterprise: @garden3d, realm_id: "g-realm",
                                      client_id: "x", client_secret: "y")
    @clients = 3.times.map do |i|
      ForecastClient.create!(forecast_id: 900_001 + i, name: "Backfill Co #{i}")
    end
  end

  def teardown
    InvoicePass.reset_column_information
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  def build_pass_with_trackers(month, qbo_accounts)
    pass = InvoicePass.create!(start_of_month: month, enterprise: @sanctuary, data: {})
    qbo_accounts.each_with_index do |qa, i|
      InvoiceTracker.create!(invoice_pass: pass, qbo_account: qa,
                             forecast_client: @clients[i])
    end
    InvoicePass.where(id: pass.id).update_all(enterprise_id: nil)
    pass
  end

  test "assigns the modal qbo_account's enterprise to a single-enterprise pass" do
    pass = build_pass_with_trackers(Date.new(2095, 1, 1), [@sanctuary_qa, @sanctuary_qa])

    BackfillInvoicePassEnterprises.new.up

    assert_equal @sanctuary, pass.reload.enterprise
  end

  test "splits a mixed pass, moving minority trackers to their own enterprise's pass" do
    pass = build_pass_with_trackers(
      Date.new(2095, 2, 1),
      [@sanctuary_qa, @sanctuary_qa, @garden3d_qa],
    )

    BackfillInvoicePassEnterprises.new.up

    assert_equal @sanctuary, pass.reload.enterprise
    assert_equal 2, pass.invoice_trackers.count

    garden3d_pass = InvoicePass.find_by(start_of_month: Date.new(2095, 2, 1),
                                        enterprise: @garden3d)
    assert garden3d_pass.present?, "expected a garden3d pass for the month"
    assert_equal 1, garden3d_pass.invoice_trackers.count
    assert_equal @garden3d_qa, garden3d_pass.invoice_trackers.first.qbo_account
    assert garden3d_pass.data["created_by_backfill"],
      "a pass the backfill created must be tagged so `down` only removes its own"
  end

  test "assigns Sanctuary to a pass with no trackers" do
    pass = InvoicePass.create!(start_of_month: Date.new(2095, 3, 1),
                               enterprise: @sanctuary, data: {})
    InvoicePass.where(id: pass.id).update_all(enterprise_id: nil)

    BackfillInvoicePassEnterprises.new.up

    assert_equal @sanctuary, pass.reload.enterprise
  end

  test "leaves no pass without an enterprise" do
    build_pass_with_trackers(Date.new(2095, 4, 1), [@sanctuary_qa, @garden3d_qa])

    BackfillInvoicePassEnterprises.new.up

    assert_equal 0, InvoicePass.where(enterprise_id: nil).count
  end

  test "a tied tracker count resolves to Sanctuary, deterministically" do
    pass = build_pass_with_trackers(Date.new(2095, 6, 1), [@sanctuary_qa, @garden3d_qa])

    BackfillInvoicePassEnterprises.new.up

    assert_equal @sanctuary, pass.reload.enterprise,
      "a tie must resolve to Sanctuary, the historical issuer"
    tagged = InvoicePass.find_by(start_of_month: Date.new(2095, 6, 1), enterprise: @garden3d)
    assert tagged.present?
    assert tagged.data["created_by_backfill"]
  end

  test "down re-merges only the passes the backfill created" do
    pass = build_pass_with_trackers(Date.new(2095, 5, 1), [@sanctuary_qa, @garden3d_qa])
    BackfillInvoicePassEnterprises.new.up

    # A legitimate garden3d pass that the backfill did NOT create must survive.
    untagged = InvoicePass.create!(start_of_month: Date.new(2095, 9, 1),
                                   enterprise: @garden3d, data: {})

    BackfillInvoicePassEnterprises.new.down

    assert_equal 2, pass.reload.invoice_trackers.count
    assert_nil InvoicePass.find_by(start_of_month: Date.new(2095, 5, 1),
                                   enterprise: @garden3d)
    assert untagged.reload.persisted?, "an untagged pass must not be destroyed"
  end
end
