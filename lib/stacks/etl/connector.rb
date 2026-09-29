module Stacks
  module Etl
    class Connector
      # Re-scan recent meetings each run so a transcript that finalized AFTER the run
      # which first saw the meeting still gets pulled (transcripts generate async).
      LOOKBACK = 2.days

      # Max chunks embedded per Embedder.embed call (bounds peak memory on long meetings).
      EMBED_BATCH = 32

      # track: advance/read the shared per-source SourceSync cursor. Multi-user sweeps
      # and explicit backfills pass their own `since` and set track:false so they don't
      # clobber the ongoing single-user cursor (or each other's).
      def run(since: nil, track: true)
        sync = track ? SourceSync.for(source) : nil
        effective_since = since || sync&.cursor&.dig('since')
        count = 0
        # `extract` may return a lazy Enumerator (it does for Meet), so we iterate it
        # directly — one meeting's transcript is in memory at a time, not the whole org.
        extract(since: effective_since).each do |normalized|
          ingest(normalized)
          count += 1
        end
        sync&.advance!(cursor: { 'since' => (Time.current - LOOKBACK).iso8601 }, stats: { 'documents' => count })
        sync
      end

      # The privacy wall is DEFAULT-DENY: every source must state, explicitly, how it walls off
      # 1:1 / HR / comp content. A new source that forgets raises here on its first document and
      # ingests nothing, rather than silently flowing everything into the agent's corpus.
      # Returns [excluded, excluded_reason]; `doc` is the Document being (re)classified.
      class MissingPrivacyPolicy < StandardError; end

      # raw_metadata keys that survive a re-ingest by a source that doesn't send them.
      def preserved_metadata_keys = [ContentReview::MEMO_KEY]

      # How kept keys and the source's fresh raw_metadata combine: by default a key the source
      # sends wins. Connectors override this for facts that must only ever get stricter.
      def merge_metadata(kept, incoming) = kept.merge(incoming)

      def exclusion_for(_normalized, _doc = nil)
        raise MissingPrivacyPolicy, "#{self.class} must implement #exclusion_for — the privacy wall is default-deny"
      end

      # Chunk + embed + resolve speakers for one document from the given segments.
      # A class method so the Reindexer can index from STORED segments (no connector,
      # no Google re-fetch) when a human re-includes a previously-excluded document.
      def self.index_chunks!(document, segments)
        document.chunks.destroy_all
        chunk_rows = Chunker.call(segments: Array(segments))
        return if chunk_rows.empty?

        participants = document.document_contacts.map { |dc| { name: dc.name, contact: dc.contact } }
        # Embed in batches so one very long meeting (hundreds of chunks) doesn't run the
        # local ONNX model over every chunk at once and spike memory past the dyno limit.
        embeddings = chunk_rows.map { |c| c[:content] }
                               .each_slice(EMBED_BATCH)
                               .flat_map { |batch| Embedder.embed(batch)[:vectors] }

        chunk_rows.each_with_index do |row, i|
          speaker = row[:speaker_email].present? ? MentionResolver.resolve_email(row[:speaker_email], name: row[:speaker_name]) : nil
          chunk = document.chunks.create!(
            position: i, content: row[:content],
            start_offset: row[:start_offset], end_offset: row[:end_offset],
            speaker_name: row[:speaker_name], speaker_contact: speaker,
            source: document.source, occurred_at: row[:occurred_at]
          )
          resolve_mention(chunk, row, participants, speaker)
          Embedding.create!(owner: chunk, model: Embedder::MODEL, embedding: embeddings[i])
        end
      end

      def self.resolve_mention(chunk, row, participants, speaker)
        return if speaker.present? || row[:speaker_name].blank?
        r = MentionResolver.resolve_display_name(row[:speaker_name], participants: participants)
        chunk.update!(speaker_contact: r[:contact]) if r[:contact]
        chunk.mentions.create!(raw_text: row[:speaker_name], contact: r[:contact], confidence: r[:confidence], status: r[:status])
      end

      private

      def ingest(normalized)
        doc = Document.find_or_initialize_by(source: normalized[:source] || source, external_id: normalized[:external_id])
        changed = doc.new_record? || doc.content_hash != normalized[:content_hash]
        # Carry privacy facts across re-ingests (e.g. the content-review memo, keyed by content
        # hash). Everything else in raw_metadata is the source's, and a key the source DOES send wins.
        kept = doc.raw_metadata.to_h.slice(*preserved_metadata_keys)

        doc.assign_attributes(
          title: normalized[:title], url: normalized[:url],
          occurred_at: normalized[:occurred_at], content_hash: normalized[:content_hash],
          raw_metadata: merge_metadata(kept, normalized[:raw_metadata] || {})
        )
        # Decide BEFORE opening the transaction: the content review is a model call (seconds,
        # with retries) and must not hold a transaction open.
        decision = exclusion_for(normalized, doc) unless doc.human_locked?

        ActiveRecord::Base.transaction do
          # A human decision always wins, including one made while we were deciding above:
          # re-read the wall state under a row lock before writing ours.
          decision = nil if keep_human_decision!(doc)
          doc.source_record = normalized[:build_source_record]&.call(doc) if changed
          doc.excluded, doc.excluded_reason = decision if decision
          doc.save!

          sync_document_contacts(doc, normalized[:contacts])

          # Index when content changed OR when a corpus-eligible doc has no chunks yet
          # (self-heal: e.g. a doc just re-included by a human gets indexed on the next sweep).
          if doc.corpus_eligible? && (changed || doc.chunks.empty?)
            self.class.index_chunks!(doc, normalized[:segments])
          elsif !doc.corpus_eligible? && (changed || !doc.reason_unreviewed?)
            # Walled off: drop the chunks. The one exception is a transient `unreviewed` hold on
            # unchanged content — its chunks stay (every read path hides them via corpus_eligible)
            # because notes and group threads cannot be re-indexed without a Google re-fetch.
            doc.chunks.destroy_all
          end
        end
      end

      # True (and the in-memory doc synced to the DB) when a human has decided on this doc.
      def keep_human_decision!(doc)
        return false unless doc.persisted?
        fresh = Document.lock.select(:id, :excluded, :excluded_reason, :excluded_by).find(doc.id)
        return false unless fresh.human_locked?
        doc.excluded, doc.excluded_reason, doc.excluded_by = fresh.excluded, fresh.excluded_reason, fresh.excluded_by
        true
      end

      def sync_document_contacts(doc, contacts)
        doc.document_contacts.destroy_all
        seen = Set.new
        Array(contacts).each do |c|
          contact = c[:email].present? ? MentionResolver.resolve_email(c[:email], name: c[:name]) : nil
          # Two attendees can resolve to the SAME Contact (a duplicated/expanded invite).
          # The (document_id, contact_id, role) unique index would then raise RecordNotUnique
          # mid-transaction and roll back the whole meeting, so skip the duplicate. Rows with
          # an unresolved (nil) contact are left alone — NULLs don't collide in the index.
          next if contact && !seen.add?([contact.id, c[:role]])
          doc.document_contacts.create!(contact: contact, email: c[:email], name: c[:name], role: c[:role])
        end
      end
    end
  end
end
