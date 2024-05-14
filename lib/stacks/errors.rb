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
end