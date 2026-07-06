require "test_helper"

class ProfitShareTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @ps = ProfitShare.new
  end

end
