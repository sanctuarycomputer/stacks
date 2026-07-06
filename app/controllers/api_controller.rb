class ApiController < ActionController::Base
  include HandlesExceptions

  rescue_from ::StandardError do |exception|
    stacks_exception_handler(exception)
  end

  def check_private_api_key!
    if request.headers["X-Api-Key"] != Stacks::Utils.config[:stacks][:private_api_key]
      raise Stacks::Errors::Unauthorized.new('Invalid API Key')
    end
  end
end
