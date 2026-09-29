# Keeps the X-Api-Key secret out of error and performance reports.
#
# Sentry sends every HTTP_* request header with each error and each sampled trace, and it reads them from this
# same Rack env hash, after the request has run. So we move the key out of the header slot, before anything else
# sees it, into a private env slot that isn't a header. Sentry skips it, and callers read it with ApiKeyVault.read.
class ApiKeyVault
  HEADER = "HTTP_X_API_KEY".freeze
  SLOT = "stacks.api_key".freeze

  def self.read(request)
    request.env[SLOT].to_s
  end

  def initialize(app)
    @app = app
  end

  def call(env)
    env[SLOT] = env.delete(HEADER) if env.key?(HEADER)
    @app.call(env)
  end
end
