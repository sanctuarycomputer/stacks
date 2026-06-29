module Stacks
  module Etl
    class Connector
      # Re-scan recent meetings each run so a transcript that finalized AFTER the run
      # which first saw the meeting still gets pulled (transcripts generate async).
      LOOKBACK = 2.days

      # track: advance/read the shared per-source SourceSync cursor. Multi-user sweeps
      # and explicit backfills pass their own `since` and set track:false so they don't
      # clobber the ongoing single-user cursor (or each other's).
      def run(since: nil, track: true)
        sync = track ? SourceSync.for(source) : nil
        effective_since = since || sync&.cursor&.dig('since')
        count = 0
        Array(extract(since: effective_since)).each do |normalized|
          ingest(normalized)
          count += 1
        end
        sync&.advance!(cursor: { 'since' => (Time.current - LOOKBACK).iso8601 }, stats: { 'documents' => count })
        sync
      end

      def exclusion_for(_normalized) = [:not_excluded, :none]

      # Chunk + embed + resolve speakers for one document from the given segments.
      # A class method so the Reindexer can index from STORED segments (no connector,
      # no Google re-fetch) when a human re-includes a previously-excluded document.
      def self.index_chunks!(document, segments)
        document.chunks.destroy_all
        chunk_rows = Chunker.call(segments: Array(segments))
        return if chunk_rows.empty?

        participants = document.document_contacts.map { |dc| { name: dc.name, contact: dc.contact } }
        embeddings = Embedder.embed(chunk_rows.map { |c| c[:content] })[:vectors]

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
        ActiveRecord::Base.transaction do
          doc = Document.find_or_initialize_by(source: source, external_id: normalized[:external_id])
          changed = doc.new_record? || doc.content_hash != normalized[:content_hash]

          doc.assign_attributes(
            title: normalized[:title], url: normalized[:url],
            occurred_at: normalized[:occurred_at], content_hash: normalized[:content_hash],
            raw_metadata: normalized[:raw_metadata] || {}
          )
          doc.source_record = normalized[:build_source_record]&.call(doc) if changed
          apply_exclusion(doc, normalized) unless doc.human_locked?
          doc.save!

          sync_document_contacts(doc, normalized[:contacts])

          # Index when content changed OR when a corpus-eligible doc has no chunks yet
          # (self-heal: e.g. a doc just re-included by a human gets indexed on the next sweep).
          if doc.corpus_eligible? && (changed || doc.chunks.empty?)
            self.class.index_chunks!(doc, normalized[:segments])
          elsif !doc.corpus_eligible?
            doc.chunks.destroy_all
          end
        end
      end

      def apply_exclusion(doc, normalized)
        excluded, reason = exclusion_for(normalized)
        doc.excluded = excluded
        doc.excluded_reason = reason
      end

      def sync_document_contacts(doc, contacts)
        doc.document_contacts.destroy_all
        Array(contacts).each do |c|
          contact = c[:email].present? ? MentionResolver.resolve_email(c[:email], name: c[:name]) : nil
          doc.document_contacts.create!(contact: contact, email: c[:email], name: c[:name], role: c[:role])
        end
      end
    end
  end
end
