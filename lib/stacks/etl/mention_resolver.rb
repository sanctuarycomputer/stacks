module Stacks
  module Etl
    class MentionResolver
      def self.resolve_email(email, name: nil)
        Contact.resolve_email(email, name: name)
      end

      def self.resolve_display_name(name, participants:)
        needle = name.to_s.downcase.strip
        exact = participants.select { |p| p[:name].to_s.downcase.strip == needle }
        return resolved(exact.first[:contact], 1.0) if exact.size == 1

        partial = participants.select do |p|
          full = p[:name].to_s.downcase
          full.split.include?(needle) || full.include?(needle)
        end
        return resolved(partial.first[:contact], 0.6) if partial.size == 1
        return { contact: nil, confidence: nil, status: 'ambiguous' } if partial.size > 1

        { contact: nil, confidence: nil, status: 'unresolved' }
      end

      def self.resolved(contact, confidence)
        { contact: contact, confidence: confidence, status: 'resolved' }
      end
    end
  end
end
