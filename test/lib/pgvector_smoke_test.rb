require 'test_helper'

class PgvectorSmokeTest < ActiveSupport::TestCase
  test 'vector extension is enabled' do
    skip_without_pgvector # pgvector isn't available on e.g. Heroku CI's in-dyno Postgres
    result = ActiveRecord::Base.connection.execute("SELECT 1 FROM pg_extension WHERE extname = 'vector'")
    assert_equal 1, result.ntuples
  end
end
