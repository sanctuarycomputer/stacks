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
        after = decide(doc, stats)
        stats["#{before.join('/')} -> #{after.join('/')}"] += 1 if after != before
        return if @dry_run

        ActiveRecord::Base.transaction do
          doc.excluded, doc.excluded_reason = after
          doc.save! if doc.changed? # also persists recorded head-counts / review memos
          if !doc.corpus_eligible?
            doc.chunks.destroy_all
          elsif after != before && doc.chunks.empty?
            Reindexer.call(doc)
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

        decision = @meet.deterministic_exclusion(normalized, doc)
        stats[:would_content_review] += 1 if doc.meet? && decision == [:not_excluded, :none] && !memo_fresh?(doc)
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
          # Only load the transcript when the review will actually read it.
          segments: doc.meet? && meeting && !memo_fresh?(doc) ? stored_segments(meeting) : []
        }
      end

      def stored_segments(meeting)
        meeting.segments.order(:position).map { |s| { speaker_name: s.speaker_name, text: s.text } }
      end

      def memo_fresh?(doc)
        memo = doc.raw_metadata&.dig(ContentReview::MEMO_KEY)
        memo.present? && doc.content_hash.present? && memo['content_hash'] == doc.content_hash
      end
    end
  end
end
