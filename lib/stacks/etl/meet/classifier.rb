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
          # Privacy-first: a head-count of 2 or fewer flags a 1:1 — and that INCLUDES 0,
          # which means "couldn't confirm a group" (e.g. the Meet participants endpoint
          # returned empty). We would rather conservatively wall off an unsized meeting
          # (a human can re-include it) than risk leaking a private 1:1 into the org-wide
          # corpus. `nil` means no count signal was supplied at all -> title rules only.
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
