module Stacks
  module Etl
    module Meet
      # Meet conference records carry only a join code, and Drive transcripts only a
      # doc name — neither has the real meeting title or the attendee emails. We
      # recover both by matching the meeting to a Calendar event on the impersonated
      # user's calendar (by Meet code when known, else by start time). Best-effort:
      # returns the fallback title and no attendees on any miss/error, so enrichment
      # never breaks ingestion.
      class CalendarEnricher
        WINDOW = 2.hours

        # => { title: String|nil, attendees: [{ email:, name: }], organizer_email: String|nil }
        def self.enrich(user_email:, started_at:, meeting_code: nil, fallback_title: nil)
          new(user_email).enrich(started_at: started_at, meeting_code: meeting_code, fallback_title: fallback_title)
        end

        # One enricher per user; the Calendar service (and its token) is built once,
        # lazily, and reused across all of that user's meetings.
        def initialize(user_email)
          @user_email = user_email
        end

        # Matches PRECISELY: by Meet code (Meet API path) or exact event title
        # (Drive path, where we have the doc-name title but no code). We deliberately
        # do NOT fall back to "nearest event by time" — that mis-assigns a recurring
        # meeting's title/attendees to an unrelated ad-hoc call.
        def enrich(started_at:, meeting_code:, fallback_title:, title_hint: nil)
          at = coerce_time(started_at)
          return miss(fallback_title) if at.nil?

          resp = service.list_events('primary',
                                     time_min: (at - WINDOW).utc.iso8601,
                                     time_max: (at + WINDOW).utc.iso8601,
                                     single_events: true, max_results: 50)
          event = pick_event(Array(resp.items), meeting_code, title_hint)
          return miss(fallback_title) unless event

          { title: event.summary.presence || fallback_title,
            attendees: attendees_for(event),
            organizer_email: event.organizer&.email&.downcase }
        rescue StandardError
          miss(fallback_title)
        end

        private

        # A no-match/error result: the doc-name fallback title, no attendees, no organizer.
        def miss(fallback_title)
          { title: fallback_title, attendees: [], organizer_email: nil }
        end

        def service
          @service ||= Auth.calendar_service(sub: @user_email)
        end

        def pick_event(events, meeting_code, title_hint)
          if meeting_code.present?
            events.find { |e| e.conference_data&.conference_id == meeting_code }
          elsif title_hint.present?
            hint = normalize_title(title_hint)
            matches = events.select { |e| normalize_title(e.summary) == hint }
            # Only enrich when the title match is UNAMBIGUOUS. If two different meetings
            # share a title in the window, attaching either one's attendees would mis-
            # attribute the meeting — better to skip enrichment than assign the wrong people.
            matches.size == 1 ? matches.first : nil
          end
        end

        # Compare titles on letters/digits only, so emoji and punctuation drift between a
        # Drive doc name ("🤝 Business Meeting 🤝") and the Calendar summary ("Business
        # Meeting") doesn't drop the match (and with it, all the attendee emails).
        def normalize_title(str)
          str.to_s.downcase.gsub(/[^\p{L}\p{N}]+/, ' ').strip
        end

        def attendees_for(event)
          Array(event.attendees).filter_map do |a|
            email = a.email&.downcase
            next if email.nil? || email.end_with?('resource.calendar.google.com') # skip rooms
            { email: email, name: a.display_name.presence }
          end
        end

        def coerce_time(t)
          return t if t.is_a?(Time) || t.is_a?(ActiveSupport::TimeWithZone)
          Time.parse(t.to_s) rescue nil
        end
      end
    end
  end
end
