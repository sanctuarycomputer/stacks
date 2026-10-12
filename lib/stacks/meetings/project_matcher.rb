module Stacks
  module Meetings
    # Nightly matcher connecting Google Meet meetings to the ProjectTracker(s)
    # they were about, so what Stacksbot observes in a transcript can be filed
    # under the right project. Modelled on Stacks::WeeklyShips::Sweep: one
    # cheap model call per meeting, a scan row so a meeting is matched once,
    # human_locked scans untouchable. The match belongs to the Meeting; its
    # transcript and Gemini notes are two documents of the same row.
    #
    # Privacy: the prompt is built only from corpus-eligible documents (their
    # titles, chunks and contacts). Never from meeting.segments, which hold the
    # transcript's text even when the transcript document is walled off.
    class ProjectMatcher
      CONFIDENCE_THRESHOLD = 0.6
      WINDOW = 14.days          # only recent meetings; no silent backfill
      BODY_CHARS = 2_000        # per document
      BODY_CHUNKS = 5           # per document
      MAX_PER_RUN = 60          # cost guard: about 7 new meetings a night today
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

      # Off until a human turns it on (heroku config:set MEETING_MATCHING=on), the
      # same trust gate as the weekly ship grader. The dry-run preview ignores it.
      def self.enabled?
        ENV["MEETING_MATCHING"].to_s.strip.downcase == "on"
      end

      def self.run!(dry_run: false, limit: MAX_PER_RUN)
        return { skipped_disabled: 1, errored: 0 } unless dry_run || enabled?
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
        trackers = meetings.any? ? candidate_trackers : []
        meetings.each { |meeting| process(meeting, trackers, stats) }
        Rails.logger.info("[meetings:match] #{stats.except(:results).inspect}")
        stats
      end

      private

      # Meetings the corpus can read at least one document of.
      def readable_meeting_ids
        Document.corpus_eligible.where(source_record_type: "Meeting").select(:source_record_id)
      end

      # Recent readable meetings that have not been matched against what they
      # now contain, newest first, at most @limit. About a hundred rows are in
      # the window, so the per-meeting hash query is affordable.
      def candidates
        # Only trackers a meeting could be matched to: a new internal tracker
        # must not send every unmatched meeting back to the model.
        newest_tracker_at = open_client_trackers.map(&:created_at).compact.max
        due = []
        Meeting.where(started_at: WINDOW.ago..).where(id: readable_meeting_ids)
               .includes(:meeting_project_scan).order(started_at: :desc, id: :desc).each do |meeting|
          break if due.size >= @limit
          due << meeting if due?(meeting, meeting.meeting_project_scan, newest_tracker_at)
        end
        due
      end

      def due?(meeting, scan, newest_tracker_at)
        return true if scan.nil?
        return false if scan.human_locked?
        return true if scan.scanned_hash != meeting.eligible_content_hash
        # Kickoff retry: a meeting held before its tracker existed gets another look.
        scan.no_match? && newest_tracker_at.present? && newest_tracker_at > scan.scanned_at
      end

      # A matched meeting whose documents have all since been walled off: what
      # the matcher wrote about it (the rationale was written from that text)
      # goes too. Not limited to the window. A person's corrections stay.
      def remove_unreadable!(stats)
        MeetingProjectScan.where(human_locked: false).where.not(meeting_id: readable_meeting_ids).find_each do |scan|
          MeetingProjectScan.transaction do
            destroy_llm_links!(MeetingProjectTracker.where(meeting_id: scan.meeting_id))
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

      def process(meeting, trackers, stats)
        # Notes first: they are the summary, and the title comes from the first.
        docs = Meeting.notes_first(meeting.eligible_documents.to_a)
        return if docs.empty?
        # Hashed from the documents the prompt is built from, not read again: a
        # document that changes after this load leaves a stale hash and is
        # matched again tomorrow.
        content_hash = Meeting.content_hash_for(docs)
        # Never meeting.title: it can have been written by an excluded document.
        title = meeting.eligible_title(docs) || "(untitled)"

        stats[:scanned] += 1
        result = Stacks::AI.extract(system: SYSTEM_PROMPT, prompt: prompt_for(meeting, docs, title, trackers), schema: SCHEMA)
        stats[:input_tokens] += result.input_tokens.to_i
        stats[:output_tokens] += result.output_tokens.to_i
        data = result.data
        # The model's output is not trusted to be in range, short, or even a string.
        confidence = data["confidence"].to_f.clamp(0.0, 1.0)
        rationale = data["rationale"].to_s.squish.first(RATIONALE_CHARS)

        candidate_ids = trackers.map { |t| t[:id] }
        ids = Array(data["tracker_ids"]).uniq & candidate_ids
        ids = [] if confidence < CONFIDENCE_THRESHOLD

        if @dry_run
          stats[:results] << { meeting_id: meeting.id, title: title, tracker_ids: ids,
                               confidence: confidence, rationale: rationale }
          return
        end

        outcome = write!(meeting, ids, candidate_ids, confidence, rationale, content_hash)
        stats[outcome] += 1 if outcome
      rescue StandardError => e
        # Timeouts and socket errors are not wrapped by the provider. No scan row, so retried next night.
        Rails.logger.error("[meetings:match] meeting=#{meeting.id} failed: #{e.class}: #{e.message}")
        stats[:errored] += 1
      end

      # Returns the outcome written, or nil when a person locked the meeting
      # while the model was answering (their judgment stands; nothing is written).
      def write!(meeting, ids, candidate_ids, confidence, rationale, content_hash)
        outcome = nil
        MeetingProjectScan.transaction do
          scan = MeetingProjectScan.lock.find_by(meeting_id: meeting.id)
          next if scan&.human_locked?

          ids.each do |tracker_id|
            link = MeetingProjectTracker.find_or_initialize_by(meeting_id: meeting.id, project_tracker_id: tracker_id)
            link.via_matcher = true
            link.assign_attributes(confidence: confidence, rationale: rationale)
            link.save!
          end
          # Only links the model was offered and did not return. A link to a
          # tracker that is no longer a candidate (completed since) is left alone.
          destroy_llm_links!(MeetingProjectTracker.where(meeting_id: meeting.id, project_tracker_id: candidate_ids - ids))

          outcome = MeetingProjectTracker.where(meeting_id: meeting.id).exists? ? :linked : :no_match
          scan ||= MeetingProjectScan.new(meeting_id: meeting.id)
          scan.update!(outcome: outcome, scanned_at: Time.zone.now, scanned_hash: content_hash)
        end
        outcome
      end

      # The matcher only ever removes its own links, and marks the removal as
      # its own so the link's callbacks do not lock the scan.
      def destroy_llm_links!(links)
        links.llm.each do |link|
          link.via_matcher = true
          link.destroy!
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
