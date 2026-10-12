module Stacks
  module Meetings
    # Nightly matcher connecting Google Meet meetings to the ProjectTracker(s)
    # they were about, so what Stacksbot observes in a transcript can be filed
    # under the right project. The sibling of Stacks::WeeklyShips::Sweep and
    # meant to behave the same: content-hash-keyed re-scans, one cheap model
    # call per candidate, 90-day backfill bound (older meetings are recorded
    # out_of_scope and never sent to the model), links added and never
    # removed, human_locked scans untouchable, no switch (it runs whenever the
    # nightly task runs).
    #
    # Deliberate differences from the ship sweep:
    # - The match is keyed on the Meeting, not on a document: a transcript and
    #   its Gemini notes are two documents of one meeting.
    # - Candidate trackers are open trackers that are not internal_client?.
    # - The prompt gives each tracker's client and team
    #   (ProjectTracker#matcher_people).
    # - The rules in SYSTEM_PROMPT: most meetings match nothing, and an
    #   interview or a conversation with a prospect never matches.
    # - A meeting the corpus can no longer read at all loses its scan and its
    #   links (remove_unreadable!). A ship is a single document, so the ship
    #   sweep has no such case; this is the only time links are removed here.
    #
    # Privacy: the prompt is built only from corpus-eligible documents (their
    # titles, chunks and contacts). Never from meeting.segments, which hold the
    # transcript's text even when the transcript document is walled off.
    class Sweep
      CONFIDENCE_THRESHOLD = 0.6
      BACKFILL_WINDOW = 90.days
      BODY_CHARS = 2_000        # per document
      BODY_CHUNKS = 5           # per document
      RECENT_PEOPLE = 60.days
      RATIONALE_CHARS = 300     # stored and shown; the model is asked for one sentence

      SCHEMA = {
        "type" => "object",
        "properties" => {
          "tracker_ids" => { "type" => "array", "items" => { "type" => "integer" } },
          "confidence" => { "type" => "number" },
          "rationale" => { "type" => "string" }
        },
        "required" => %w[tracker_ids confidence rationale],
        "additionalProperties" => false
      }.freeze

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You match an internal Google Meet meeting to the client project(s) it was about.

        Rules:
        - Most meetings are internal (standups, one-off chats, company meetings, hiring,
          sales calls about work not yet won) and match NO project. Returning an empty
          list is the normal, correct answer for those.
        - An interview or conversation with a job candidate, a contractor being
          considered, or a prospective client never matches a project, whoever else
          is in the room.
        - Match only when the meeting is clearly a working or client meeting about a
          specific candidate project: the title or the conversation names the client
          or the project, or the people present are that project's team and the talk
          is about that project's work.
        - Studio names (Sanctuary Computer, XXIX, Manhattan Hydraulics, Index, garden3d)
          are ours, not a client. Never match on them alone.
        - People are matched by name or email. One shared person is weak evidence: the
          same people work on several projects.
        - A meeting may be about more than one candidate project.
        - Only include tracker ids you are genuinely confident about; confidence is
          your overall 0-1 confidence in the ids you returned.
        - rationale is one short sentence naming the evidence. Do not quote the
          conversation.
      PROMPT

      # A normal run takes no limit and has no cap. The dry-run preview writes
      # nothing and may be limited to the newest few meetings.
      def self.run!(dry_run: false, limit: nil)
        raise ArgumentError, "only a dry run takes a limit" if limit && !dry_run
        new(dry_run: dry_run, limit: limit).run!
      end

      def initialize(dry_run:, limit:)
        @dry_run = dry_run
        @limit = limit
      end

      def run!
        stats = Hash.new(0)
        stats[:results] = [] if @dry_run
        unless Stacks::AI.configured?
          stats[:skipped_no_key] = candidates.size
          Rails.logger.warn("[meetings:match] No AI key configured, skipped #{stats[:skipped_no_key]} meetings")
          return stats
        end
        remove_unreadable!(stats) unless @dry_run
        meetings = candidates
        if @dry_run
          # The preview shows what the model would say: meetings it would not be asked about are left out.
          meetings = meetings.select { |meeting| in_window?(held_at(meeting)) }
          meetings = meetings.first(@limit) if @limit
        end
        trackers = meetings.any? { |meeting| in_window?(held_at(meeting)) } ? candidate_trackers : []
        meetings.each { |meeting| process(meeting, trackers, stats) }
        Rails.logger.info("[meetings:match] #{stats.except(:results).inspect}")
        stats
      end

      private

      # Meetings the corpus can read at least one document of.
      def readable_meeting_ids
        Document.corpus_eligible.where(source_record_type: "Meeting").select(:source_record_id)
      end

      # Every readable meeting that has no scan, or whose scan a person has not
      # locked and was made from different content, newest first. The hashes
      # are compared in Ruby from two queries, not one query per meeting.
      def candidates
        docs_by_meeting = Document.corpus_eligible.where(source_record_type: "Meeting")
                                  .select(:id, :content_hash, :occurred_at, :source_record_id)
                                  .group_by(&:source_record_id)
        @document_dates = docs_by_meeting.transform_values { |docs| docs.map(&:occurred_at).compact.max }
        scans = MeetingScan.where(meeting_id: docs_by_meeting.keys).pluck(:meeting_id, :human_locked, :scanned_hash)
                           .index_by(&:first)
        due_ids = docs_by_meeting.select do |meeting_id, docs|
          _, human_locked, scanned_hash = scans[meeting_id]
          scans[meeting_id].nil? || (!human_locked && scanned_hash != Meeting.content_hash_for(docs))
        end.keys
        Meeting.where(id: due_ids).order(Arel.sql("started_at DESC NULLS LAST"), id: :desc).to_a
      end

      # A matched meeting whose documents have all since been walled off: what
      # the sweep wrote about it goes too (the reason was written from that
      # text, and there is nothing left to base the links on). Not limited to
      # the window. A person's corrections stay.
      def remove_unreadable!(stats)
        MeetingScan.where(human_locked: false).where.not(meeting_id: readable_meeting_ids).find_each do |scan|
          MeetingScan.transaction do
            scan.meeting.project_trackers.clear
            scan.destroy!
          end
          stats[:removed] += 1
        end
      end

      # Client work only. Trackers for our own companies (internal_client?) are
      # left out: a hiring interview or a company meeting would otherwise be
      # filed under whichever internal tracker shares the most people.
      def open_client_trackers
        @open_client_trackers ||= ProjectTracker.where(work_completed_at: nil)
                                                .includes(forecast_projects: :forecast_client)
                                                .reject(&:internal_client?)
      end

      def candidate_trackers
        open_client_trackers.map do |pt|
          { id: pt.id, names: ([pt.name] + pt.forecast_projects.map(&:name)).compact.uniq,
            client: pt.derived_client&.name, people: pt.matcher_people }
        end
      end

      # When the meeting was held. A meeting row with no start time is dated by
      # its newest eligible document.
      def held_at(meeting)
        meeting.started_at || @document_dates[meeting.id]
      end

      def in_window?(held)
        held.present? && held >= BACKFILL_WINDOW.ago
      end

      def process(meeting, trackers, stats)
        # Notes first: they are the summary, and the title comes from the first.
        docs = Meeting.notes_first(meeting.eligible_documents.to_a)
        return if docs.empty?
        # Hashed from the documents the prompt is built from, not read again: a
        # document that changes after this load leaves a stale hash and is
        # matched again tomorrow.
        content_hash = Meeting.content_hash_for(docs)
        held = held_at(meeting)
        stats[:scanned] += 1
        # A meeting with no date at all cannot be placed in the window. It is
        # recorded like an old one, so it is not an error every night.
        if held.nil? || !in_window?(held)
          stats[:out_of_scope] += 1 if record_out_of_scope!(meeting, content_hash)
          return
        end

        # Never meeting.title: it can have been written by an excluded document.
        title = meeting.eligible_title(docs) || "(untitled)"
        result = Stacks::AI.extract(system: SYSTEM_PROMPT, prompt: prompt_for(meeting, docs, title, trackers), schema: SCHEMA)
        stats[:input_tokens] += result.input_tokens.to_i
        stats[:output_tokens] += result.output_tokens.to_i
        data = result.data
        # The model's output is not trusted to be in range, short, or even a string.
        confidence = data["confidence"].to_f.clamp(0.0, 1.0)
        rationale = data["rationale"].to_s.squish.first(RATIONALE_CHARS)

        ids = Array(data["tracker_ids"]).uniq & trackers.map { |t| t[:id] }
        ids = [] if confidence < CONFIDENCE_THRESHOLD

        if @dry_run
          stats[:results] << { meeting_id: meeting.id, title: title, tracker_ids: ids,
                               confidence: confidence, rationale: rationale }
          return
        end

        outcome = link!(meeting, ids, confidence, rationale, content_hash)
        stats[outcome] += 1 if outcome
      rescue StandardError => e
        # Timeouts and socket errors are not wrapped by the provider. No scan row, so retried next night.
        Rails.logger.error("[meetings:match] meeting=#{meeting.id} failed: #{e.class}: #{e.message}")
        stats[:errored] += 1
      end

      # Adds the trackers the model returned and records the scan. Existing
      # links are left alone, whatever the model said this time: like the ship
      # sweep, a rescan never destroys a link. Returns the outcome written, or
      # nil when a person locked the meeting while the model was answering
      # (their judgment stands; nothing is written).
      def link!(meeting, ids, confidence, rationale, content_hash)
        outcome = nil
        MeetingScan.transaction do
          scan = MeetingScan.lock.find_by(meeting_id: meeting.id)
          next if scan&.human_locked?

          # The join is written directly: Meeting#link_project! is a person's change and locks the scan.
          have = meeting.project_trackers.reset.ids
          new_ids = ids - have
          meeting.project_trackers << open_client_trackers.select { |tracker| new_ids.include?(tracker.id) }

          outcome = (have + new_ids).any? ? :linked : :no_match
          scan ||= MeetingScan.new(meeting_id: meeting.id)
          scan.update!(outcome: outcome, confidence: confidence, rationale: rationale,
                       scanned_at: Time.zone.now, scanned_hash: content_hash)
        end
        outcome
      end

      # Older than the backfill window: recorded, so it is not looked at again
      # until its content changes, and never sent to the model. Any reason an
      # earlier scan stored goes: the hash now names content it was not written from.
      def record_out_of_scope!(meeting, content_hash)
        return true if @dry_run
        MeetingScan.transaction do
          scan = MeetingScan.lock.find_by(meeting_id: meeting.id) || MeetingScan.new(meeting_id: meeting.id)
          next false if scan.human_locked?
          # A meeting that already has projects keeps saying so.
          outcome = meeting.project_trackers.exists? ? :linked : :out_of_scope
          scan.update!(outcome: outcome, confidence: nil, rationale: nil,
                       scanned_at: Time.zone.now, scanned_hash: content_hash)
          true
        end
      end

      def prompt_for(meeting, docs, title, trackers)
        doc_ids = docs.map(&:id)
        people = meeting.participants.pluck(:name) +
                 Chunk.where(document_id: doc_ids).distinct.pluck(:speaker_name) +
                 DocumentContact.where(document_id: doc_ids).pluck(:name, :email).map { |name, email| person_label(name, email) }
        people = people.compact.map(&:strip).reject(&:blank?).uniq
        opening = docs.map { |d| d.chunks.order(:position).limit(BODY_CHUNKS).pluck(:content).join("\n")[0, BODY_CHARS] }.join("\n")

        <<~PROMPT
          Meeting title: #{title}
          Held: #{meeting.started_at&.to_date}
          People present or speaking: #{people.join(", ").presence || "unknown"}

          Opening of the meeting (truncated):
          #{opening}

          Candidate project trackers:
          #{trackers.map { |t| tracker_line(t) }.join("\n")}
        PROMPT
      end

      def tracker_line(tracker)
        line = "- id #{tracker[:id]}: #{tracker[:names].join(" / ")}"
        line += " (client: #{tracker[:client]})" if tracker[:client].present?
        line += " (team: #{tracker[:people].join(", ")})" if tracker[:people].any?
        line
      end

      def person_label(name, email)
        return name if email.blank?
        [name.presence, "<#{email}>"].compact.join(" ")
      end
    end
  end
end
