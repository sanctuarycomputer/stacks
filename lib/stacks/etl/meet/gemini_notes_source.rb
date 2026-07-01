require "digest"
module Stacks
  module Etl
    module Meet
      class GeminiNotesSource
        include DriveDoc
        QUERY = "mimeType='application/vnd.google-apps.document' and name contains 'Notes by Gemini'".freeze

        def initialize(user_email, since:, until_time: nil)
          @user_email = user_email
          @since = coerce(since)
          @until_time = coerce(until_time) # notes have no overlap guard; callers pass nil
          @service = Auth.drive_service(sub: user_email)
        end

        private

        def transcript_doc_id_from(text)
          # The "Meeting records [Transcript](…/document/d/<id>/…)" line.
          m = text.to_s.match(%r{\[Transcript\]\(https://docs\.google\.com/document/d/([A-Za-z0-9_-]+)})
          m && m[1]
        end

        def invited_emails_from(text)
          # Emails only appear as mailto: links, primarily in the "Invited" block.
          text.to_s.scan(/mailto:([^)\s]+)/).flatten.map { |e| e.downcase }
              .reject { |e| e.end_with?("resource.calendar.google.com") }.uniq
        end

        def body_segments(text, occurred_at:)
          # Search-only: the whole notes body IS the searchable content. Split into
          # paragraph-ish blocks so the Chunker has natural boundaries; drop the trailing
          # Gemini feedback/footer noise.
          cleaned = text.to_s.gsub(/We've updated the Decisions section.*\z/m, "")
                        .gsub(/Let us know what you think.*\z/m, "")
                        .gsub(/You should review Gemini's notes.*\z/m, "")
          cleaned.split(/\n{2,}/).map(&:strip).reject(&:empty?).map do |para|
            { speaker_name: nil, speaker_email: nil, text: para, started_at: occurred_at, ended_at: nil }
          end
        end
      end
    end
  end
end
