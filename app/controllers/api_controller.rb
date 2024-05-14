class ApiController < ActionController::Base
  include HandlesExceptions

  rescue_from ::StandardError do |exception|
    # If we're handling an exception from an ActiveAdmin route,
    # we capture the exception and expose the full error message
    # to the admin. Otherwise, we pass the exception to our main
    # application exception handler.
    if controller_path =~ /^admin\//i
      flash[:warning] = exception.message
      redirect_back(fallback_location: root_path)
    else
      stacks_exception_handler(exception)
    end
  end

  def check_private_api_key!
    if request.headers["X-Api-Key"] != Stacks::Utils.config[:stacks][:private_api_key]
      raise Stacks::Errors::Unauthorized.new('Invalid API Key')
    end
  end
end
