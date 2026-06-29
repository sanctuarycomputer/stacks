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
          # Only a KNOWN small head-count (1 or 2) flags a 1:1. A count of 0 means
          # "unknown" — e.g. the Meet participants endpoint returned empty on a glitch —
          # and must NOT auto-exclude a legitimately large meeting; title rules still apply.
          return [:auto_excluded, :one_on_one] if participant_count&.positive? && participant_count <= 2
          RULES.each do |reason, rx|
            return [:auto_excluded, reason] if title.to_s.match?(rx)
          end
          [:not_excluded, :none]
        end
      end
    end
  end
end
