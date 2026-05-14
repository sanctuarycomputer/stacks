require "test_helper"

class ContributorQboVendorForTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "cqv#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
  end

  test "qbo_vendor_for returns nil when no mapping exists" do
    assert_nil @contributor.qbo_vendor_for(@sanctuary_qa)
  end

  test "qbo_vendor_for returns nil when qbo_account is nil" do
    assert_nil @contributor.qbo_vendor_for(nil)
  end

  test "qbo_vendor_for returns the vendor record scoped to that qbo_account" do
    vendor = QboVendor.create!(qbo_id: "VENDOR#{SecureRandom.hex(3)}", qbo_account: @sanctuary_qa, data: { "display_name" => "Test" })
    ContributorQboVendor.create!(contributor: @contributor, qbo_account: @sanctuary_qa, qbo_vendor: vendor)
    assert_equal vendor, @contributor.qbo_vendor_for(@sanctuary_qa)
  end

  test "qbo_vendor_for returns nil when a different qbo_account is provided" do
    vendor = QboVendor.create!(qbo_id: "VENDOR#{SecureRandom.hex(3)}", qbo_account: @sanctuary_qa, data: { "display_name" => "Test" })
    ContributorQboVendor.create!(contributor: @contributor, qbo_account: @sanctuary_qa, qbo_vendor: vendor)

    other_ent = Enterprise.find_or_create_by!(name: "Other-#{SecureRandom.hex(2)}")
    other_qa = QboAccount.create!(enterprise: other_ent, client_id: "x", client_secret: "y", realm_id: SecureRandom.hex(8))
    assert_nil @contributor.qbo_vendor_for(other_qa)
  end

  test "rejects a mapping where qbo_vendor belongs to a different qbo_account" do
    other_ent = Enterprise.find_or_create_by!(name: "Mismatch-#{SecureRandom.hex(2)}")
    other_qa = QboAccount.create!(enterprise: other_ent, client_id: "x", client_secret: "y", realm_id: SecureRandom.hex(8))
    # Vendor lives in `other_qa`, but the mapping says qbo_account = sanctuary_qa
    cross = QboVendor.create!(qbo_id: "CROSS#{SecureRandom.hex(3)}", qbo_account: other_qa, data: {})
    mapping = ContributorQboVendor.new(contributor: @contributor, qbo_account: @sanctuary_qa, qbo_vendor: cross)
    refute mapping.valid?
    assert_includes mapping.errors[:qbo_vendor], "must belong to the same qbo_account as the mapping"
  end

  test "backfilled mapping resolves to a qbo_vendor whose qbo_id matches the legacy column" do
    c = Contributor.where.not(qbo_vendor_id: nil).first
    next if c.nil?
    found_vendor = c.qbo_vendor_for(@sanctuary_qa)
    assert_not_nil found_vendor
    assert_equal c.qbo_vendor_id, found_vendor.qbo_id
  end

  # Edge case: qbo_vendor_for returns the vendor across multiple qbo_accounts correctly
  test "qbo_vendor_for returns correct vendor when contributor has mappings to multiple qbo_accounts" do
    # Create a second enterprise and QBO account
    garden3d = Enterprise.find_or_create_by!(name: "Garden3D-#{SecureRandom.hex(2)}")
    garden3d_qa = QboAccount.create!(
      enterprise: garden3d,
      client_id: "garden3d_client",
      client_secret: "garden3d_secret",
      realm_id: "garden3d_realm_#{SecureRandom.hex(4)}"
    )

    # Create two vendors: one for Sanctuary, one for Garden3D
    vendor_a = QboVendor.create!(
      qbo_id: "VENDOR_A_#{SecureRandom.hex(3)}",
      qbo_account: @sanctuary_qa,
      data: { "display_name" => "Vendor A (Sanctuary)" }
    )
    vendor_b = QboVendor.create!(
      qbo_id: "VENDOR_B_#{SecureRandom.hex(3)}",
      qbo_account: garden3d_qa,
      data: { "display_name" => "Vendor B (Garden3D)" }
    )

    # Map the contributor to both vendors
    ContributorQboVendor.create!(
      contributor: @contributor,
      qbo_account: @sanctuary_qa,
      qbo_vendor: vendor_a
    )
    ContributorQboVendor.create!(
      contributor: @contributor,
      qbo_account: garden3d_qa,
      qbo_vendor: vendor_b
    )

    # Verify each account returns its correct vendor
    assert_equal vendor_a, @contributor.qbo_vendor_for(@sanctuary_qa)
    assert_equal vendor_b, @contributor.qbo_vendor_for(garden3d_qa)

    # Verify the two vendors have different qbo_ids and qbo_account_ids
    assert_not_equal vendor_a.qbo_id, vendor_b.qbo_id
    assert_not_equal vendor_a.qbo_account_id, vendor_b.qbo_account_id
  end

  # Edge case: qbo_vendor presence validation
  test "ContributorQboVendor validates qbo_vendor presence" do
    mapping = ContributorQboVendor.new(
      contributor: @contributor,
      qbo_account: @sanctuary_qa,
      qbo_vendor: nil
    )
    refute mapping.valid?
    # belongs_to validates with "must exist" not "can't be blank"
    assert_includes mapping.errors[:qbo_vendor], "must exist"
  end

  # qbo_account presence still required — but is derived from qbo_vendor when
  # only a vendor is supplied (so the admin form can omit a redundant qa
  # dropdown). Verified here by leaving BOTH fields blank.
  test "ContributorQboVendor validates qbo_account presence when neither qbo_account nor qbo_vendor is supplied" do
    mapping = ContributorQboVendor.new(contributor: @contributor)
    refute mapping.valid?
    # belongs_to validates with "must exist" not "can't be blank"
    assert_includes mapping.errors[:qbo_account], "must exist"
  end

  test "ContributorQboVendor derives qbo_account from vendor when qbo_account is left nil" do
    vendor = QboVendor.create!(
      qbo_id: "VENDOR#{SecureRandom.hex(3)}",
      qbo_account: @sanctuary_qa,
      data: { "display_name" => "Test" }
    )
    mapping = ContributorQboVendor.new(
      contributor: @contributor,
      qbo_account: nil,
      qbo_vendor: vendor,
    )
    assert mapping.valid?, mapping.errors.full_messages.inspect
    assert_equal @sanctuary_qa.id, mapping.qbo_account_id
  end

  # Edge case: uniqueness constraint allows different contributor/qbo_account pairs
  test "ContributorQboVendor uniqueness allows different (contributor, qbo_account) pairs" do
    vendor = QboVendor.create!(
      qbo_id: "VENDOR#{SecureRandom.hex(3)}",
      qbo_account: @sanctuary_qa,
      data: { "display_name" => "Test" }
    )

    # First mapping: contributor + sanctuary_qa
    mapping1 = ContributorQboVendor.create!(
      contributor: @contributor,
      qbo_account: @sanctuary_qa,
      qbo_vendor: vendor
    )
    assert mapping1.persisted?

    # Second mapping: different contributor, same sanctuary_qa
    fp2 = ForecastPerson.create!(
      forecast_id: rand(1..2_000_000_000),
      email: "another#{SecureRandom.hex(2)}@x.com",
      data: {}
    )
    contributor2 = Contributor.create!(forecast_person: fp2)
    mapping2 = ContributorQboVendor.create!(
      contributor: contributor2,
      qbo_account: @sanctuary_qa,
      qbo_vendor: vendor
    )
    assert mapping2.persisted?

    # Third mapping: same contributor, different qbo_account
    garden3d = Enterprise.find_or_create_by!(name: "Garden3D-#{SecureRandom.hex(2)}")
    garden3d_qa = QboAccount.create!(
      enterprise: garden3d,
      client_id: "garden3d_client",
      client_secret: "garden3d_secret",
      realm_id: "garden3d_realm_#{SecureRandom.hex(4)}"
    )
    vendor3 = QboVendor.create!(
      qbo_id: "VENDOR_G#{SecureRandom.hex(3)}",
      qbo_account: garden3d_qa,
      data: { "display_name" => "Test Garden" }
    )
    mapping3 = ContributorQboVendor.create!(
      contributor: @contributor,
      qbo_account: garden3d_qa,
      qbo_vendor: vendor3
    )
    assert mapping3.persisted?

    # Fourth mapping: duplicate of first → should be rejected by uniqueness
    mapping4 = ContributorQboVendor.new(
      contributor: @contributor,
      qbo_account: @sanctuary_qa,
      qbo_vendor: vendor
    )
    refute mapping4.valid?
    assert_includes mapping4.errors[:contributor_id], "has already been taken"
  end

  # Edge case: qbo_vendor_for returns nil after the underlying QboVendor is destroyed
  test "qbo_vendor_for raises FK constraint error when trying to destroy vendor with active mapping" do
    vendor = QboVendor.create!(
      qbo_id: "VENDOR#{SecureRandom.hex(3)}",
      qbo_account: @sanctuary_qa,
      data: { "display_name" => "Test" }
    )
    ContributorQboVendor.create!(
      contributor: @contributor,
      qbo_account: @sanctuary_qa,
      qbo_vendor: vendor
    )

    # Verify the mapping returns the vendor
    assert_equal vendor, @contributor.qbo_vendor_for(@sanctuary_qa)

    # The QboVendor has an active FK constraint from ContributorQboVendor,
    # so attempting to destroy it should raise an error
    assert_raises ActiveRecord::InvalidForeignKey do
      vendor.destroy!
    end

    # Verify the mapping still works because the vendor is still alive
    assert_equal vendor, @contributor.qbo_vendor_for(@sanctuary_qa)
  end

  # Edge case: Contributor#qbo_vendors returns all mappings via has_many :through
  test "Contributor#qbo_vendors returns all mappings via has_many through" do
    # Create a second enterprise and QBO account
    garden3d = Enterprise.find_or_create_by!(name: "Garden3D-#{SecureRandom.hex(2)}")
    garden3d_qa = QboAccount.create!(
      enterprise: garden3d,
      client_id: "garden3d_client",
      client_secret: "garden3d_secret",
      realm_id: "garden3d_realm_#{SecureRandom.hex(4)}"
    )

    # Create two vendors
    vendor_a = QboVendor.create!(
      qbo_id: "VENDOR_A_#{SecureRandom.hex(3)}",
      qbo_account: @sanctuary_qa,
      data: { "display_name" => "Vendor A" }
    )
    vendor_b = QboVendor.create!(
      qbo_id: "VENDOR_B_#{SecureRandom.hex(3)}",
      qbo_account: garden3d_qa,
      data: { "display_name" => "Vendor B" }
    )

    # No mappings yet
    assert_equal 0, @contributor.qbo_vendors.count

    # Create mappings to both vendors
    ContributorQboVendor.create!(
      contributor: @contributor,
      qbo_account: @sanctuary_qa,
      qbo_vendor: vendor_a
    )
    ContributorQboVendor.create!(
      contributor: @contributor,
      qbo_account: garden3d_qa,
      qbo_vendor: vendor_b
    )

    # Verify count is 2
    assert_equal 2, @contributor.qbo_vendors.count

    # Verify we can filter by qbo_account
    sanctuary_vendors = @contributor.qbo_vendors.where(qbo_account: @sanctuary_qa)
    assert_equal 1, sanctuary_vendors.count
    assert_equal vendor_a, sanctuary_vendors.first

    garden3d_vendors = @contributor.qbo_vendors.where(qbo_account: garden3d_qa)
    assert_equal 1, garden3d_vendors.count
    assert_equal vendor_b, garden3d_vendors.first
  end
end

class ContributorQboVendorDeriveQboAccountTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "derive#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @vendor = QboVendor.create!(qbo_id: "V#{SecureRandom.hex(3)}", qbo_account: @sanctuary_qa, data: { "display_name" => "Derive Test" })
  end

  test "qbo_account_id is derived from qbo_vendor when not explicitly set" do
    cqv = ContributorQboVendor.new(contributor: @contributor, qbo_vendor: @vendor)
    assert cqv.save
    assert_equal @sanctuary_qa.id, cqv.qbo_account_id
  end

  test "explicit qbo_account_id is preserved when it matches the vendor's" do
    cqv = ContributorQboVendor.new(contributor: @contributor, qbo_vendor: @vendor, qbo_account: @sanctuary_qa)
    assert cqv.save
    assert_equal @sanctuary_qa.id, cqv.qbo_account_id
  end

  test "mismatched qbo_account_id (set explicitly to something other than the vendor's) still fails validation" do
    other_ent = Enterprise.create!(name: "DeriveOther-#{SecureRandom.hex(2)}")
    other_qa = QboAccount.create!(enterprise: other_ent, client_id: "c", client_secret: "s", realm_id: "r#{SecureRandom.hex(2)}")
    cqv = ContributorQboVendor.new(contributor: @contributor, qbo_vendor: @vendor, qbo_account: other_qa)
    refute cqv.save
    assert_match(/same qbo_account/, cqv.errors[:qbo_vendor].join)
  end
end

class ContributorAcceptsNestedQboVendorsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "nest#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @vendor = QboVendor.create!(qbo_id: "V#{SecureRandom.hex(3)}", qbo_account: @sanctuary_qa, data: { "display_name" => "Nested Test" })
  end

  test "creates a contributor_qbo_vendors row from nested attributes (admin form path)" do
    assert_difference -> { ContributorQboVendor.where(contributor_id: @contributor.id).count }, 1 do
      @contributor.update!(contributor_qbo_vendors_attributes: [{ qbo_vendor_id: @vendor.id }])
    end
    cqv = ContributorQboVendor.find_by(contributor_id: @contributor.id, qbo_vendor_id: @vendor.id)
    assert_equal @sanctuary_qa.id, cqv.qbo_account_id, "expected qbo_account_id to be derived from the vendor"
  end

  test "blank qbo_vendor_id rows are silently rejected (reject_if)" do
    assert_no_difference -> { ContributorQboVendor.where(contributor_id: @contributor.id).count } do
      @contributor.update!(contributor_qbo_vendors_attributes: [{ qbo_vendor_id: "" }])
    end
  end

  test "destroys an existing mapping when _destroy is set" do
    cqv = ContributorQboVendor.create!(contributor: @contributor, qbo_account: @sanctuary_qa, qbo_vendor: @vendor)
    assert_difference -> { ContributorQboVendor.where(contributor_id: @contributor.id).count }, -1 do
      @contributor.update!(contributor_qbo_vendors_attributes: [{ id: cqv.id, _destroy: "1" }])
    end
  end
end
