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
end
