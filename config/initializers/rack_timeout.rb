# Heroku's router kills requests at 30s. If a Puma thread is blocked on a
# slow query past that point, the request slot stays held while Heroku has
# already returned H12 to the client — the whole dyno bleeds capacity.
#
# `service_timeout: 25` raises Rack::Timeout::RequestTimeoutError 5s before
# the router would, freeing the thread to handle the next request. We skip
# this in dev/test so debugging sessions and long test runs aren't killed.
if Rails.env.production?
  Rack::Timeout.service_timeout = 25
  Rack::Timeout.wait_timeout = 30
end
