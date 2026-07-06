module HandlesExceptions
  extend ActiveSupport::Concern

  def stacks_exception_handler(exception)
    handle_for_json(exception)
  end

  private

  def handle_for_json(exception)
    case exception
    when Stacks::Errors::Base
      render json: exception.as_json, status: exception.status
    when ActiveRecord::RecordInvalid
      error = Stacks::Errors::Validation.new('Resource could not be saved.', exception.record)
      handle_for_json(error)
    when ActionController::ParameterMissing
      error = Stacks::Errors::Validation.new('Resource could not be saved.')
      error.errors.add(exception.param.to_sym, "can't be blank")
      handle_for_json(error)
    when ActionController::InvalidAuthenticityToken
      handle_for_json(Stacks::Errors::Unauthorized.new('Invalid Authenticity Token'))
    else
      handle_for_json(Stacks::Errors::Unexpected.new('Unhandled exception', exception))
    end
  end
end