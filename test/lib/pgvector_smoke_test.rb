require 'test_helper'

class PgvectorSmokeTest < ActiveSupport::TestCase
  test 'vector extension is enabled' do
    result = ActiveRecord::Base.connection.execute("SELECT 1 FROM pg_extension WHERE extname = 'vector'")
    assert_equal 1, result.ntuples
  end
end
