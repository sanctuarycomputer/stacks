class Stacks::Utils
  class << self
    def config
      Rails.application.credentials[:"#{ENV["BASE_HOST"] || "localhost:3000"}"]
    end
  end
end
