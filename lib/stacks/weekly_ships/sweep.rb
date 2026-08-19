module Stacks
  module WeeklyShips
    # Nightly matcher connecting ships@ documents to ProjectTrackers.
    # Design notes live in docs/superpowers/specs/2026-08-18-weekly-ship-tracking-design.md —
    # notably: content-hash-keyed re-scans (reply-clobbered threads), LLM
    # classifies every candidate (heuristics only pre-rank the prompt), 90-day
    # backfill bound, human_locked scans untouchable.
    class Sweep
      CONFIDENCE_THRESHOLD = 0.6
      BACKFILL_WINDOW = 90.days
      BODY_CHARS = 2_000

      SCHEMA = {
        "type" => "object",
        "properties" => {
          "tracker_ids" => { "type" => "array", "items" => { "type" => "integer" } },
          "not_a_ship" => { "type" => "boolean" },
          "confidence" => { "type" => "number" },
          "rationale" => { "type" => "string" }
        },
        "required" => %w[tracker_ids not_a_ship confidence rationale],
        "additionalProperties" => false
      }.freeze

      OWN_BRANDS = ["sanctuary computer", "sanctuary", "xxix", "manhattan hydraulics",
                    "index", "garden3d"].freeze

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You classify internal "weekly ship" emails sent to ships@sanctuary.computer,
        matching each email to the client project(s) it reports on.

        Rules:
        - Studio brand names (Sanctuary Computer, XXIX, Manhattan Hydraulics, Index,
          Garden3D) appear in subjects as the SENDER's studio, not the project —
          never match on them alone.
        - An email may cover several projects, or none of the candidates.
        - not_a_ship is true for emails that are not weekly ship reports at all.
        - Only include tracker ids you are genuinely confident about; confidence is
          your overall 0-1 confidence in the ids you returned.
      PROMPT

      def self.run!
        new.run!
      end

      def run!
        stats = Hash.new(0)
        unless Stacks::AI.configured?
          stats[:skipped_no_key] = candidates.count
          Rails.logger.warn("[weekly_ships] No AI key configured — skipped #{stats[:skipped_no_key]} documents")
          return stats
        end

        trackers = candidate_trackers
        candidates.find_each do |doc|
          process(doc, trackers, stats)
        end
        Rails.logger.info("[weekly_ships] #{stats.inspect}")
        stats
      end

      private

      def candidates
        Document.ships_group
          .joins("LEFT JOIN ship_scans ON ship_scans.document_id = documents.id")
          .where("ship_scans.id IS NULL OR (ship_scans.human_locked = FALSE AND documents.content_hash IS DISTINCT FROM ship_scans.scanned_content_hash)")
      end

      def candidate_trackers
        ProjectTracker.where(work_completed_at: nil).map do |pt|
          names = ([pt.name] + pt.forecast_projects.map(&:name)).compact.uniq
          { id: pt.id, names: names, normalized: names.map { |n| normalize(n) } }
        end
      end

      def process(doc, trackers, stats)
        stats[:scanned] += 1
        if doc.occurred_at < BACKFILL_WINDOW.ago
          record_scan!(doc, :out_of_scope)
          stats[:out_of_scope] += 1
          return
        end

        result = Stacks::AI.extract(system: SYSTEM_PROMPT, prompt: prompt_for(doc, trackers), schema: SCHEMA)
        stats[:input_tokens] += result.input_tokens
        stats[:output_tokens] += result.output_tokens
        data = result.data

        if data["not_a_ship"]
          record_scan!(doc, :not_a_ship)
          stats[:not_a_ship] += 1
        elsif data["tracker_ids"].any? && data["confidence"].to_f >= CONFIDENCE_THRESHOLD
          link!(doc, data, trackers)
          record_scan!(doc, :linked)
          stats[:linked] += 1
        else
          Rails.logger.info("[weekly_ships] no_match doc=#{doc.id}: #{data["rationale"]}")
          record_scan!(doc, :no_match)
          stats[:no_match] += 1
        end
      rescue Stacks::AI::Error => e
        # No scan row → retried next night.
        Rails.logger.error("[weekly_ships] doc=#{doc.id} failed: #{e.message}")
        stats[:errored] += 1
      end

      def link!(doc, data, trackers)
        valid_ids = trackers.map { |t| t[:id] }
        sender_name, sender_email = sender_for(doc)

        data["tracker_ids"].uniq.each do |tracker_id|
          next unless valid_ids.include?(tracker_id)
          ship = WeeklyShip.find_or_initialize_by(document: doc, project_tracker_id: tracker_id)
          ship.via_sweep = true
          ship.matched_by ||= :llm
          ship.assign_attributes(sent_at: doc.occurred_at, sent_by_email: sender_email,
                                 sent_by_name: sender_name,
                                 confidence: data["confidence"], rationale: data["rationale"])
          ship.save!
        end
        # Reply-clobber refresh: existing links keep pace with the document but are never destroyed.
        doc.weekly_ships.where.not(project_tracker_id: data["tracker_ids"]).find_each do |ship|
          ship.via_sweep = true
          ship.update!(sent_at: doc.occurred_at, sent_by_email: sender_email, sent_by_name: sender_name)
        end
      end

      # Sender = speaker of the first chunk (reply re-ingests rebuild
      # document_contacts to the repliers, so position 0 is the reliable
      # signal); email via the matching sender contact.
      def sender_for(doc)
        first_chunk = doc.chunks.order(:position).first
        name = first_chunk&.speaker_name
        contact = doc.document_contacts.where(role: "sender").detect { |c| c.name == name } ||
                  doc.document_contacts.where(role: "sender").first
        [name || contact&.name, contact&.email]
      end

      def prompt_for(doc, trackers)
        subject = doc.title.to_s
        normalized_subject = normalize(subject)
        ranked = trackers.sort_by do |t|
          hit = t[:normalized].any? { |n| n.present? && !OWN_BRANDS.include?(n) && normalized_subject.include?(n) }
          hit ? 0 : 1
        end
        body = doc.chunks.order(:position).limit(5).pluck(:content).join("\n")[0, BODY_CHARS]
        sender_name, sender_email = sender_for(doc)

        <<~PROMPT
          Subject: #{subject}
          Sender: #{sender_name} <#{sender_email}>

          Body (truncated):
          #{body}

          Candidate project trackers (likely matches first):
          #{ranked.map { |t| "- id #{t[:id]}: #{t[:names].join(" / ")}" }.join("\n")}
        PROMPT
      end

      def record_scan!(doc, outcome)
        scan = ShipScan.find_or_initialize_by(document: doc)
        return if scan.human_locked?
        scan.update!(outcome: outcome, scanned_at: Time.zone.now, scanned_content_hash: doc.content_hash)
      end

      def normalize(s)
        s.to_s.downcase.gsub(/[^0-9a-z ]/, " ").squeeze(" ").strip
      end
    end
  end
end
