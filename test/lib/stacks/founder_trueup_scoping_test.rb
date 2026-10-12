require "test_helper"

class FounderTrueupScopingTest < ActiveSupport::TestCase
  def teardown
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  test "sync_founder_trueups! does not accept a garden3d pass as the month's pass" do
    month = Date.new(2091, 1, 1)
    InvoicePass.where(start_of_month: month).destroy_all
    InvoicePass.create!(start_of_month: month,
                        enterprise: enterprises(:garden3d), data: {})

    Stacks::System.stubs(:founder_trueup_months).returns([month])

    error = assert_raises(RuntimeError) { Stacks::System.sync_founder_trueups! }
    assert_match(/No invoice pass found/, error.message)
  end
end
