module Stacks::Errors
  class Base < StandardError
    def base_error
      {
        title: title,
        status: status,
        source: source,
        detail: detail,
      }
    end

    def as_json
      { errors: [base_error] }
    end
  end

  class Validation < Stacks::Errors::Base
    include ActiveModel::Validations

    def initialize(detail, validated = nil)
      errors.merge!(validated.errors) if validated.present?
      @validated = validated
      @detail = detail
    end

    def title
      'Invalid Request Error'
    end

    def detail
      @detail
    end

    def message
      @detail
    end

    def source
      nil
    end

    def status
      :unprocessable_entity
    end

    def validation_array
      array = []

      errors.to_hash.each_key do |key|
        array << {
          status: status,
          source: { pointer: "data/attributes/#{key}" },
          title: errors[key].uniq.join(', '),
          detail: detail,
        }
      end

      array
    end

    def as_json
      { errors: validation_array.prepend(base_error) }
    end
  end

  # Raised by a task to indicate that it intentionally did NOT run — typically
  # because some external precondition (an integration's config, a remote
  # resource's state) makes the work pointless or impossible right now. These
  # are NOT bugs; the reason should be surfaced in the admin UI and persisted
  # alongside the task, but should not page on-call (no Twist, no Sentry).
  class Skipped < Stacks::Errors::Base
  end

  class Unauthorized < Stacks::Errors::Base
    def initialize(message)
      @message = message
    end

    def title
      'Unauthorized'
    end

    def detail
      @message
    end

    def source
      nil
    end

    def status
      :forbidden
    end
  end

  # Raised by the API exception handler for genuinely-unexpected errors. Renders a
  # generic 500 that NEVER echoes the underlying exception's message (which may carry
  # upstream response bodies), while logging + Sentry-capturing the real exception.
  class Unexpected < Stacks::Errors::Base
    def initialize(detail, exception = nil)
      @detail = detail
      if exception
        Rails.logger.warn("[Stacks::Errors::Unexpected] #{exception.class}: #{exception.message}")
        Sentry.capture_exception(exception) if defined?(Sentry)
      end
    end

    def title; 'Unexpected Error'; end
    def detail; @detail; end
    def source; nil; end
    def status; :internal_server_error; end
  end
end