module Stacks
  module Etl
    class MentionResolver
      def self.resolve_email(email, name: nil)
        Contact.resolve_email(email, name: name)
      end

      def self.resolve_display_name(name, participants:)
        needle = name.to_s.downcase.strip
        candidates = participants.select { |p| p[:contact].present? }
        exact = candidates.select { |p| p[:name].to_s.downcase.strip == needle }
        return resolved(exact.first[:contact], 1.0) if exact.size == 1

        # Partial match: a spoken first name matching a fuller participant name. A needle
        # token matches a participant name token only if it equals the whole token OR is its
        # LEADING hyphen-segment. This threads two failure modes:
        #   - never substring-match  ("Chris" must NOT match "Christine")
        #   - "Anne" SHOULD match "Anne-Marie Smith" (its leading segment) so that, when an
        #     "Anne Jones" is also present, the mention resolves to 'ambiguous' (safe) rather
        #     than confidently to the wrong Anne
        #   - "Marie" (a TRAILING segment) must NOT match "Anne-Marie Smith" — too weak a
        #     signal, would mis-attribute
        needle_tokens = needle.split
        return { contact: nil, confidence: nil, status: 'unresolved' } if needle_tokens.empty?
        partial = candidates.select do |p|
          needle_tokens.all? { |nt| name_token_matches?(nt, p[:name]) }
        end
        return resolved(partial.first[:contact], 0.6) if partial.size == 1
        return { contact: nil, confidence: nil, status: 'ambiguous' } if partial.size > 1

        { contact: nil, confidence: nil, status: 'unresolved' }
      end

      # True if needle_token equals a whitespace token of name, or is that token's leading
      # segment when split on any dash — hyphen or unicode en/em dash ("anne" matches
      # "anne-marie" / "anne–marie", but "marie" and "chris" do not).
      def self.name_token_matches?(needle_token, name)
        name.to_s.downcase.split.any? { |t| t == needle_token || t.split(/[-–—]/).first == needle_token }
      end

      def self.resolved(contact, confidence)
        { contact: contact, confidence: confidence, status: 'resolved' }
      end
    end
  end
end
