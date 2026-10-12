require "test_helper"

class InvoicePassEnterpriseTest < ActiveSupport::TestCase
  test "an invoice pass requires an enterprise" do
    pass = InvoicePass.new(start_of_month: Date.new(2099, 5, 1))
    assert_not pass.valid?
    assert_includes pass.errors[:enterprise], "must exist"
  end

  test "two enterprises can each hold a pass for the same month" do
    month = Date.new(2099, 6, 1)
    sanctuary_pass = InvoicePass.create!(start_of_month: month, enterprise: enterprises(:sanctuary))
    garden3d_pass = InvoicePass.create!(start_of_month: month, enterprise: enterprises(:garden3d))

    assert sanctuary_pass.persisted?
    assert garden3d_pass.persisted?
  end

  test "one enterprise cannot hold two passes for the same month" do
    month = Date.new(2099, 7, 1)
    InvoicePass.create!(start_of_month: month, enterprise: enterprises(:sanctuary))

    # There is no uniqueness validation, only the DB index — hence
    # RecordNotUnique rather than RecordInvalid. The test transaction is
    # opened joinable: false, so this nested save gets a real savepoint and
    # does not poison the surrounding fixtures.
    assert_raises(ActiveRecord::RecordNotUnique) do
      InvoicePass.create!(start_of_month: month, enterprise: enterprises(:sanctuary))
    end
  end

  test "a new invoice tracker defaults to the forecast source" do
    assert_equal "forecast", InvoiceTracker.new.source
  end
end
