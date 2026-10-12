require "test_helper"
require Rails.root.join("db/migrate/20261013000001_add_management_fee_payer_to_enterprises.rb")

class EnterpriseManagementFeePayerTest < ActiveSupport::TestCase
  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "an enterprise is not a payer unless flagged" do
    enterprise = Enterprise.create!(name: "Unflagged #{SecureRandom.hex(3)}")

    assert_equal false, enterprise.reload.management_fee_payer
    assert_nil enterprise.g3d_qbo_customer_id
  end

  test "management_fee_payers lists only flagged enterprises" do
    payer = Enterprise.create!(name: "Payer #{SecureRandom.hex(3)}", management_fee_payer: true)
    other = Enterprise.create!(name: "Other #{SecureRandom.hex(3)}")

    ids = Enterprise.management_fee_payers.pluck(:id)

    assert_includes ids, payer.id
    refute_includes ids, other.id
  end

  test "garden3d can never be flagged as a payer" do
    garden3d = enterprises(:garden3d)
    garden3d.management_fee_payer = true

    assert_not garden3d.valid?
    assert_includes garden3d.errors[:management_fee_payer],
      "cannot be set on garden3d, LLC: it issues the management fee"
  end

  test "garden3d saves normally while unflagged" do
    assert enterprises(:garden3d).update(pay_cycle_cadence: "monthly")
  end

  # Migrations are run by hand on production, after the deploy. Until then the
  # row has no such attribute, and the validation must not run at all: every
  # Enterprise save, the nightly generate_snapshot! included, would raise.
  test "an enterprise saves while the management_fee_payer column does not exist yet" do
    garden3d = enterprises(:garden3d)
    garden3d.define_singleton_method(:has_attribute?) do |name|
      name.to_s == "management_fee_payer" ? false : super(name)
    end
    # What reading the flag does on a row that has no such column.
    garden3d.stubs(:management_fee_payer?).raises(NoMethodError, "undefined method `management_fee_payer?'")

    assert garden3d.update(pay_cycle_cadence: "monthly")
    assert_equal "monthly", Enterprise.find(garden3d.id).pay_cycle_cadence
  end

  test "the migration seeds the three payers and the two verified customer ids" do
    sanctuary = enterprises(:sanctuary)
    index = Enterprise.find_or_create_by!(name: Enterprise::INDEX_SPACE_NAME)
    usb = Enterprise.find_or_create_by!(name: Enterprise::USB_CLUB_NAME)

    AddManagementFeePayerToEnterprises.new.seed_payers!

    assert_equal [true, "2"], sanctuary.reload.values_at(:management_fee_payer, :g3d_qbo_customer_id)
    assert_equal [true, "5"], index.reload.values_at(:management_fee_payer, :g3d_qbo_customer_id)
    assert_equal [true, nil], usb.reload.values_at(:management_fee_payer, :g3d_qbo_customer_id)
  end

  test "seeding never overwrites a customer id that is already stored" do
    sanctuary = enterprises(:sanctuary)
    sanctuary.update_columns(g3d_qbo_customer_id: "99")

    AddManagementFeePayerToEnterprises.new.seed_payers!
    AddManagementFeePayerToEnterprises.new.seed_payers!

    assert_equal "99", sanctuary.reload.g3d_qbo_customer_id
    assert sanctuary.management_fee_payer
  end

  test "seeding skips a payer that is absent and never flags garden3d" do
    Enterprise.where(name: [Enterprise::INDEX_SPACE_NAME, Enterprise::USB_CLUB_NAME]).delete_all

    assert_nothing_raised { AddManagementFeePayerToEnterprises.new.seed_payers! }

    assert_equal false, enterprises(:garden3d).reload.management_fee_payer
    assert_equal false, enterprises(:one).reload.management_fee_payer
  end
end
