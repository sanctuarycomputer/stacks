module Stacks
  module WeeklyShips
    # Grades each weekly ship email once, right after the nightly sweep links it
    # to a tracker. One cheap model call per email: seven rubric dimensions
    # scored 0-2, turned into 1-5 stars here in code, plus a one-line summary and
    # one to three kind, concrete suggestions for the sender. The grade is stored
    # on every weekly_ships row for that email under metadata["scoring"].
    #
    # Design: docs/superpowers/specs/2026-09-28-weekly-ship-grading-design.md.
    # Grades are coaching for the Project Lead, not a client artifact: the
    # tracker page shows them, Stacksbot celebrates five-star ships in the
    # Monday post, and low grades are never posted publicly.
    class Grader
      RUBRIC_VERSION = 1
      WINDOW = 14.days      # only ships sent this recently are graded (no silent backfill)
      MAX_PER_RUN = 40      # cost guard: ~30 ships a month today
      BODY_CHARS = 12_000
      PREVIOUS_CHARS = 4_000
      MAX_TOKENS = 1_500
      MAX_SUGGESTIONS = 3
      OVERLAP_WORDS = Stacks::Etl::Chunker::OVERLAP_WORDS

      # key => what the grader checks. Order is the order the model scores them.
      DIMENSIONS = {
        "shipped" => "Shipped, not busy: the accomplishments are concrete, finished things " \
                     "(merged, launched, delivered, shared for review, approved, decided), not " \
                     "activity (\"worked on\", \"continued\", \"refining\").",
        "next_week" => "Next week is a promise: the plan for next week names specific outcomes " \
                       "someone could check off in the next ship.",
        "asks" => "Risks and asks are visible: blockers and risks are called out plainly, and " \
                  "each ask says who needs to do what and what it unblocks. A ship that says " \
                  "there are no blockers or asks this week scores 2 on this.",
        "timeline" => "Timeline is explicit: the next milestone or delivery date is stated, and a " \
                      "date that moved is called out as moved, not buried.",
        "money" => "Money is visible: hours and spend against the budget (or the month's budget) " \
                   "are reported in a form the client can follow. Any clear format counts; " \
                   "the Stacks numbers block is one.",
        "readable" => "Readable by the client: plain language, skimmable sections, no internal " \
                      "jargon, tool names or team shorthand the client would have to decode.",
        "continuity" => "Continuity: what the previous ship promised for this week is answered " \
                        "(done, moved, or dropped, and why).",
      }.freeze

      SCHEMA = {
        "type" => "object",
        "properties" => {
          "dimensions" => {
            "type" => "object",
            "properties" => DIMENSIONS.keys.to_h do |k|
              [k, { "type" => "object",
                    "properties" => { "why" => { "type" => "string" }, "score" => { "type" => "integer" } },
                    "required" => %w[why score], "additionalProperties" => false }]
            end,
            "required" => DIMENSIONS.keys,
            "additionalProperties" => false
          },
          "summary" => { "type" => "string" },
          "suggestions" => { "type" => "array", "items" => { "type" => "string" } }
        },
        "required" => %w[dimensions summary suggestions],
        "additionalProperties" => false
      }.freeze

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You grade "weekly ship" emails: the update a garden3d studio's project lead sends a
        client every week (what we did, what's next, what we need, how the budget is tracking).
        Your grade coaches the sender. It is never shown to the client.

        Score each dimension 0, 1 or 2 (2 = fully does it, 1 = partly, 0 = missing):
        #{DIMENSIONS.map { |k, v| "- #{k}: #{v}" }.join("\n")}

        Rules:
        - Judge only what is in the email. Never state a fact the email does not state (do not
          call a project over budget or late unless the email says so).
        - Do not reward length: a short ship that is concrete scores higher than a long one
          that is vague.
        - An honest "we slipped" or "we are over budget" is good practice. Never mark a
          dimension down for bad news that is stated plainly.
        - A monthly or end-of-month summary is graded on the same dimensions.
        - If there is no previous ship, score continuity 0 with why "no previous ship"; it is
          not counted.
        - "why" is one short sentence that quotes or points at the email.

        Then write, for the sender:
        - summary: one warm sentence on what this ship does well.
        - suggestions: one to three concrete, kind suggestions for the next ship, most
          valuable first, each one or two short sentences. Each names the specific thing to
          add or change, using this email's own content ("Say when the ticketing decision is
          due, and who makes it"), never generic advice ("be clearer"). Frame each as what to
          add next time, not what was wrong. If the ship is excellent, one small suggestion
          is enough.
        Write plainly, like a helpful colleague talking to the sender ("you"). No scores,
        stars or rubric names in the summary or suggestions. No em dashes.
      PROMPT

      # 7 dims × 2 = 14 points (12 without a previous ship). Thresholds reproduce the
      # rubric's 13–14 ★5 · 10–12 ★4 · 7–9 ★3 · 4–6 ★2 · 0–3 ★1 on the full scale.
      STAR_THRESHOLDS = [[0.9, 5], [0.7, 4], [0.5, 3], [0.25, 2]].freeze

      # Off until a human turns it on (heroku config:set WEEKLY_SHIP_GRADING=on), the same
      # trust gate as Stacksbot's Enabled checkbox. The dry-run preview ignores it.
      def self.enabled?
        ENV["WEEKLY_SHIP_GRADING"].to_s.strip.downcase == "on"
      end

      def self.run!(dry_run: false, limit: MAX_PER_RUN)
        return { skipped_disabled: 1, errored: 0 } unless dry_run || enabled?
        new(dry_run: dry_run, limit: limit).run!
      end

      def self.stars_for(dimensions, has_previous:)
        keys = DIMENSIONS.keys
        keys -= ["continuity"] unless has_previous
        points = keys.sum { |k| dimensions.dig(k, "score").to_i }
        share = points.to_f / (keys.size * 2)
        STAR_THRESHOLDS.find { |min, _| share >= min }&.last || 1
      end

      # The sender's own words: the first speaker's chunks, with the chunker's
      # 40-word slice overlap removed, cut before quoted replies and the Groups footer.
      def self.ship_text(doc)
        chunks = doc.chunks.order(:position).to_a
        first_speaker = chunks.first&.speaker_name
        words = []
        chunks.take_while { |c| c.speaker_name == first_speaker }.each do |c|
          w = c.content.to_s.split
          w = w.drop(OVERLAP_WORDS) if words.any? && w.first(OVERLAP_WORDS) == words.last(OVERLAP_WORDS)
          words.concat(w)
        end
        text = words.join(" ")
        text = text.split(/\s*-- You received this message because/, 2).first.to_s
        text = text.split(/\s+>+\s*On\s.{1,160}?wrote:|\s+On\s[^>]{1,160}?wrote:\s*>/, 2).first.to_s
        text.strip[0, BODY_CHARS]
      end

      def self.build_prompt(subject:, sender:, sent_at:, text:, previous_text:, previous_sent_at:)
        previous =
          if previous_text.present?
            days = previous_sent_at ? ((sent_at - previous_sent_at) / 1.day).round : nil
            "Previous ship to this client (sent #{days ? "#{days} days before" : "earlier"}):\n" \
              "#{previous_text[0, PREVIOUS_CHARS]}"
          else
            "No previous ship on record for this project."
          end

        <<~PROMPT
          Ship to grade
          Subject: #{subject}
          Sender: #{sender}
          Sent: #{sent_at&.to_date}

          #{text}

          ---
          #{previous}
        PROMPT
      end

      def initialize(dry_run:, limit:)
        @dry_run = dry_run
        @limit = limit
      end

      def run!
        stats = Hash.new(0)
        stats[:results] = [] if @dry_run
        doc_ids = candidate_document_ids
        unless Stacks::AI.configured?
          stats[:skipped_no_key] = doc_ids.size
          return stats
        end

        Document.where(id: doc_ids).each { |doc| grade(doc, stats) }
        Rails.logger.info("[weekly_ships:grade] #{stats.except(:results).inspect}")
        stats
      end

      private

      def candidate_document_ids
        WeeklyShip.corpus_eligible
          .where(sent_at: WINDOW.ago..)
          .where("weekly_ships.metadata -> 'scoring' IS NULL")
          .group("weekly_ships.document_id")
          .order(Arel.sql("MAX(weekly_ships.sent_at) DESC"))
          .limit(@limit)
          .pluck("weekly_ships.document_id")
      end

      def grade(doc, stats)
        ships = WeeklyShip.where(document_id: doc.id).to_a
        # A tracker linked after the email was graded gets the same grade, not a regrade.
        if (existing = ships.map { |ws| ws.metadata["scoring"] }.compact.first)
          stamp!(ships, existing) unless @dry_run
          stats[:copied] += 1
          return
        end
        ship = ships.first
        previous = previous_ship(ships)
        previous_text = previous && self.class.ship_text(previous.document)

        result = Stacks::AI.extract(
          system: SYSTEM_PROMPT, schema: SCHEMA, max_tokens: MAX_TOKENS,
          prompt: self.class.build_prompt(subject: doc.title, sender: ship.sent_by_name.presence || ship.sent_by_email,
                                          sent_at: ship.sent_at, text: self.class.ship_text(doc),
                                          previous_text: previous_text, previous_sent_at: previous&.sent_at)
        )
        stats[:input_tokens] += result.input_tokens
        stats[:output_tokens] += result.output_tokens
        scoring = scoring_from(result.data, has_previous: previous_text.present?)

        if @dry_run
          stats[:results] << { document_id: doc.id, subject: doc.title, scoring: scoring }
        else
          stamp!(ships, scoring)
        end
        stats[:graded] += 1
      rescue Stacks::AI::Error, ActiveRecord::ActiveRecordError => e
        # Nothing written → retried next night while the ship is inside WINDOW.
        Rails.logger.error("[weekly_ships:grade] doc=#{doc.id} failed: #{e.message}")
        stats[:errored] += 1
      end

      def stamp!(ships, scoring)
        ships.each do |ws|
          next if ws.metadata["scoring"] == scoring
          ws.via_sweep = true # a machine write: never human-lock the scan
          ws.update!(metadata: ws.metadata.merge("scoring" => scoring))
        end
      end

      # The newest earlier ship (any document) on any of this email's trackers.
      def previous_ship(ships)
        WeeklyShip.corpus_eligible.includes(:document)
          .where(project_tracker_id: ships.map(&:project_tracker_id))
          .where.not(document_id: ships.first.document_id)
          .where("weekly_ships.sent_at < ?", ships.map(&:sent_at).min)
          .order(sent_at: :desc).first
      end

      # Validates the model's output (a malformed grade is an error, never stored)
      # and computes the stars in code.
      def scoring_from(data, has_previous:)
        dims = data["dimensions"]
        raise Stacks::AI::Error, "grade has no dimensions" unless dims.is_a?(Hash)
        DIMENSIONS.each_key do |k|
          score = dims.dig(k, "score")
          raise Stacks::AI::Error, "#{k} score #{score.inspect} is not 0, 1 or 2" unless [0, 1, 2].include?(score)
        end
        suggestions = Array(data["suggestions"]).map { |s| tidy(s) }.reject(&:empty?).first(MAX_SUGGESTIONS)
        raise Stacks::AI::Error, "grade has no suggestions" if suggestions.empty?
        summary = tidy(data["summary"])
        raise Stacks::AI::Error, "grade has no summary" if summary.empty?

        {
          "rubric_version" => RUBRIC_VERSION,
          "stars" => self.class.stars_for(dims, has_previous: has_previous),
          "dimensions" => DIMENSIONS.keys.to_h { |k| [k, { "score" => dims[k]["score"], "why" => dims[k]["why"].to_s }] },
          "continuity_counted" => has_previous,
          "summary" => summary,
          "suggestions" => suggestions,
          "model" => Stacks::AI.model_for(:fast),
          "graded_at" => Time.zone.now.iso8601,
        }
      end

      # House style: the model still reaches for em dashes now and then.
      def tidy(text)
        text.to_s.strip.gsub(/\s*[—–]\s*/, ", ")
      end
    end
  end
end
