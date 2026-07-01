module Stacks
  module Etl
    module Meet
      # Shared helpers for Google Meet Drive Docs (transcripts + Gemini notes), whose
      # names share the same "<Title> - <date> <tz> - <Kind>" shape.
      module DriveDoc
        # Strips the "- Transcript" / " - Notes by Gemini" suffix, then Meet's date stamp
        # in either the parenthetical "(2026/06/27 17:00 GMT-7)" or dash
        # "- 2026/06/22 17:15 EDT" form. Requires a real date + clock time so a normal title
        # like "Planning - Q3" or "Retro (5:00 format)" survives.
        SUFFIX = /\s*-\s*(?:Transcript|Notes by Gemini)\s*\z/i
        PAREN_DATE_STAMP = %r{\s*\((?:\d{2,4}[/-]\d{1,2}[/-]\d{1,2}|[^)]*\bGMT\b)[^)]*\)\s*\z}
        DASH_DATE_STAMP  = %r{\s*-\s*\d{2,4}[/-]\d{1,2}[/-]\d{1,2}\s+\d{1,2}:\d{2}(?:\s*[AP]M)?(?:\s+[A-Za-z0-9+\-]{2,6})?\s*\z}i

        def clean_title(name)
          name.to_s.sub(SUFFIX, "").sub(PAREN_DATE_STAMP, "").sub(DASH_DATE_STAMP, "").strip.presence || name.to_s
        end

        def coerce(t)
          return nil if t.nil?
          t.is_a?(String) ? Time.parse(t) : t
        end
      end
    end
  end
end
