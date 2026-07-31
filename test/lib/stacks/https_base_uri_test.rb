require "test_helper"

# Regression guard for a silent, production-only class of bug:
#
# A scheme-less HTTParty `base_uri` (e.g. "api.forecastapp.com") defaults to
# http://. Forecast (and Twist) 301-redirect http -> https. GETs survive the
# redirect, but a redirected POST/PUT/DELETE arrives malformed and the API
# returns 400 — so READS work while WRITES silently fail. Stubbed unit tests
# never catch it because they don't hit the network; it only surfaces against
# the live API. `Stacks::Forecast#create_assignment` hitting this is exactly
# what stopped recurring-assignment materialization from reaching Forecast.
#
# Pin every HTTParty API client to an explicit https base_uri.
class Stacks::HttpsBaseUriTest < ActiveSupport::TestCase
  CLIENTS = [
    Stacks::Forecast,
    Stacks::Twist,
    Stacks::Runn,
    Stacks::Deel,
    Stacks::Notion,
    Stacks::Apollo,
  ].freeze

  test "every HTTParty API client uses an https base_uri (writes must not ride an http->https redirect)" do
    CLIENTS.each do |klass|
      assert klass.base_uri.to_s.start_with?("https://"),
        "#{klass}.base_uri must be https to avoid write-mangling redirects; got #{klass.base_uri.inspect}"
    end
  end
end
