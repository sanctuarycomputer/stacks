module Stacks
  module Etl
    # The deterministic half of the privacy wall, shared by every source: a head-count rule
    # for meetings plus a title lexicon. It runs FIRST; the Meet connector then sends whatever
    # it lets through to Stacks::Etl::ContentReview (the LLM half).
    #
    # The lexicon favours precision on words that ordinary studio work uses all the time:
    # bare "feedback", "review" and "check-in" are NOT rules (prod had 129 group threads titled
    # "feedback", mostly client design feedback). Personal-feedback phrasings are.
    class Classifier
      RULES = [
        # "1:1", "1-1", "1 on 1" — but NOT a bare "11" ("Sprint 11", "Sep 11": the old optional
        # separator matched those, 328 group threads in prod).
        [:one_on_one,         /\b1\s*[:\-]\s*1s?\b|\b1\s*-?\s*on\s*-?\s*1s?\b|\bone[\s-]on[\s-]ones?\b|\bskip[\s-]?levels?\b/i],
        [:performance_review, /\b(performance|perf) reviews?\b|\bpromotions?\b|\b(peer|360|upward|downward|performance|career) feedback\b|\b360s?\b/i],
        [:compensation,       /\bsalar(y|ies)\b|\bcomp(ensation)?\b|\braises?\b|\bbonus(es)?\b|\bequity\b|\bpayroll\b|\bpay (reviews?|bands?|increases?|equity|cuts?)\b|\brate increases?\b|\boffer letters?\b|\bseverance\b/i],
        [:hr,                 /\bhr\b|\bdisciplinary\b|\bgrievances?\b|\binvestigations?\b|\bharass(ment|ed|ing)?\b|\b(medical|parental|maternity|paternity|sick|bereavement) leave\b|\bleave of absence\b/i],
        [:offboarding,        /\boffboarding\b|\btermination\b|\blay[\s-]?offs?\b|\bresign(ation|ing|ed)?\b|\bexit interviews?\b/i],
        [:pip,                /\bpip\b/i]
      ].freeze

      def self.call(title:, participant_count:)
        # Privacy-first: a head-count of 2 or fewer flags a 1:1 — and that INCLUDES 0,
        # which means "couldn't confirm a group" (e.g. the Meet participants endpoint
        # returned empty). We would rather conservatively wall off an unsized meeting
        # (a human can re-include it) than risk leaking a private 1:1 into the org-wide
        # corpus. `nil` means no count signal was supplied at all -> title rules only.
        return [:auto_excluded, :one_on_one] if participant_count && participant_count <= 2
        title_exclusion(title) || [:not_excluded, :none]
      end

      # [:auto_excluded, reason] when the title names a sensitive topic, else nil.
      def self.title_exclusion(title)
        RULES.each do |reason, rx|
          return [:auto_excluded, reason] if title.to_s.match?(rx)
        end
        nil
      end
    end
  end
end
