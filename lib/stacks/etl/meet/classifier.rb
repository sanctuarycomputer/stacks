module Stacks
  module Etl
    module Meet
      class Classifier
        RULES = [
          [:one_on_one,         /\b1\s*[:\-]?\s*1\b|\bone[\s-]on[\s-]one\b/i],
          [:performance_review, /\bperformance review\b/i],
          [:compensation,       /\bsalary\b|\bcomp(ensation)?\b/i],
          [:hr,                 /\bhr\b/i],
          [:offboarding,        /\boffboarding\b|\btermination\b/i],
          [:pip,                /\bpip\b/i]
        ].freeze

        def self.call(title:, participant_count:)
          return [:auto_excluded, :one_on_one] if participant_count && participant_count <= 2
          RULES.each do |reason, rx|
            return [:auto_excluded, reason] if title.to_s.match?(rx)
          end
          [:not_excluded, :none]
        end
      end
    end
  end
end
