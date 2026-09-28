module Stacks
  module Etl
    # Re-applies the privacy wall to documents ALREADY stored, from stored data only (Meeting,
    # segments, contacts, title — no Google re-fetch), using the same connector policies ingest
    # uses. One mechanism for: the backfill after a rule change, retrying `unreviewed` docs, and
    # keeping notes in step with their transcript. Runs nightly in stacks:etl:sync_all.
    #
    # Human decisions (manually_included / manually_excluded) are never touched.
    # Newly walled-off docs lose their chunks. A transcript that becomes eligible is re-indexed
    # from its stored segments; notes and group threads have no stored text, so they wait for
    # their next sync.
    class Reclassifier
      # Transcripts first, so notes inherit decisions made earlier in the same run.
      ORDER = %w[meet gemini_notes google_groups].freeze
      HUMAN = [Document.excludeds[:manually_included], Document.excludeds[:manually_excluded]].freeze

      def self.call(dry_run: false, scope: Document.all)
        new(dry_run: dry_run).call(scope)
      end

      def initialize(dry_run:)
        @dry_run = dry_run
        @meet = Meet::Connector.new(admin_email: nil)
        @groups = Groups::Connector.new(admin_email: nil)
      end

      def call(scope)
        stats = Hash.new(0)
        ORDER.each do |src|
          scope.where(source: src).where.not(excluded: HUMAN).find_each { |doc| process(doc, stats) }
        end
        Rails.logger.info("[privacy] reclassify#{' (dry run)' if @dry_run}: #{stats.inspect}")
        stats
      end

      private

      def process(doc, stats)
        stats[:checked] += 1
        before = [doc.excluded.to_sym, doc.excluded_reason.to_sym]
        after = decide(doc, stats) # may call the model: done OUTSIDE the transaction
        stats["#{before.join('/')} -> #{after.join('/')}"] += 1 if after != before
        return if @dry_run

        ActiveRecord::Base.transaction do
          # Re-read under a row lock: a human may have decided while the model was thinking,
          # and a human decision always wins.
          fresh = Document.lock.find(doc.id)
          if fresh.human_locked?
            stats[:skipped_human_decided_meanwhile] += 1
            next
          end
          fresh.excluded, fresh.excluded_reason = after
          # Persist only what we computed (recorded head-counts, review memo), not stale fields.
          fresh.raw_metadata = (fresh.raw_metadata || {}).merge(
            doc.raw_metadata.to_h.slice(ContentReview::MEMO_KEY, Meet::Connector::INPUTS_KEY)
          )
          fresh.save! if fresh.changed?
          if !fresh.corpus_eligible?
            # A transient `unreviewed` hold keeps its (hidden) chunks: notes and group threads
            # cannot be re-indexed without a Google re-fetch.
            fresh.chunks.destroy_all unless fresh.reason_unreviewed?
          elsif fresh.chunks.empty?
            Reindexer.call(fresh)
          end
        end
      rescue StandardError => e
        stats[:errored] += 1
        Rails.logger.error("[privacy] reclassify failed for document #{doc.id}: #{e.class}: #{e.message.to_s[0, 200]}")
      end

      def decide(doc, stats)
        return @groups.exclusion_for({ title: doc.title }, doc) if doc.google_groups?

        normalized = stored_normalized(doc)
        return @meet.exclusion_for(normalized, doc) unless @dry_run

        # Dry run: rules only. Notes see their transcript's CURRENT state (not what this run would
        # decide for it), and content-review outcomes are counted, not predicted.
        decision = @meet.deterministic_exclusion(normalized, doc)
        stats[:would_content_review] += 1 if decision == [:not_excluded, :none] && !ContentReview.fresh_memo(doc)
        decision
      end

      def stored_normalized(doc)
        meta = doc.raw_metadata || {}
        inputs = meta[Meet::Connector::INPUTS_KEY]
        meeting = doc.source_record.is_a?(Meeting) ? doc.source_record : nil
        {
          source: doc.source.to_sym,
          title: doc.title,
          transcript_doc_id: meta['transcript_doc_id'],
          # Prefer the head-counts ingest recorded; legacy docs fall back to stored rows.
          participant_count: inputs ? inputs['participant_count'] : meeting&.participant_count.to_i,
          invite_count: inputs ? inputs['invite_count'] : doc.document_contacts.count,
          content_hash: doc.content_hash,
          # Only load text when the review will actually read it. A transcript's text is its
          # stored segments; a notes doc's only stored text is its own chunks (none once walled
          # off, which the review treats as unreviewed — fail closed).
          segments: ContentReview.fresh_memo(doc) ? [] : stored_text(doc, meeting)
        }
      end

      def stored_text(doc, meeting)
        return stored_segments(meeting) if doc.meet? && meeting
        return doc.chunks.order(:position).pluck(:content).map { |c| { text: c } } if doc.gemini_notes?
        []
      end

      def stored_segments(meeting)
        meeting.segments.order(:position).map { |s| { speaker_name: s.speaker_name, text: s.text } }
      end
    end
  end
end
