class ApiController < ActionController::Base
  include HandlesExceptions

  rescue_from ::StandardError do |exception|
    stacks_exception_handler(exception)
  end

  def check_private_api_key!
    # constant-time compare: this key now gates a mutation surface too
    provided = request.headers["X-Api-Key"].to_s
    expected = Stacks::Utils.config[:stacks][:private_api_key].to_s
    unless ActiveSupport::SecurityUtils.secure_compare(provided, expected)
      raise Stacks::Errors::Unauthorized.new('Invalid API Key')
    end
  end
end
