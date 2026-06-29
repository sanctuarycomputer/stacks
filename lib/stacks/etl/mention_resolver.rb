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

        # Partial match on WHOLE name tokens (a spoken first name matching a fuller
        # participant name), never on raw substrings — substring matching wrongly resolves
        # "Chris" -> "Christine" or "an" -> "Joanna" and mis-attributes who said what.
        # Tokenize on any non-letter run so hyphenated/compound names split too, letting
        # "Anne" still resolve to "Anne-Marie Smith" without resurrecting substring matching.
        needle_tokens = tokenize(needle)
        return { contact: nil, confidence: nil, status: 'unresolved' } if needle_tokens.empty?
        partial = candidates.select do |p|
          (needle_tokens - tokenize(p[:name])).empty?
        end
        return resolved(partial.first[:contact], 0.6) if partial.size == 1
        return { contact: nil, confidence: nil, status: 'ambiguous' } if partial.size > 1

        { contact: nil, confidence: nil, status: 'unresolved' }
      end

      def self.resolved(contact, confidence)
        { contact: contact, confidence: confidence, status: 'resolved' }
      end

      # Lowercase name tokens, splitting on any non-letter run so "Anne-Marie" -> [anne, marie].
      def self.tokenize(name)
        name.to_s.downcase.split(/[^\p{L}]+/).reject(&:empty?)
      end
    end
  end
end
