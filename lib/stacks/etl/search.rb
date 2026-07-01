module Stacks
  module Etl
    class Search
      def self.call(query:, mode: :hybrid, source: nil, contact: nil, date_range: nil, limit: 20)
        base = filtered(Chunk.corpus_eligible, source: source, contact: contact, date_range: date_range)
        ids =
          case mode.to_sym
          when :keyword  then keyword_ids(base, query, limit)
          when :semantic then semantic_ids(base, query, limit)
          else fuse(keyword_ids(base, query, limit), semantic_ids(base, query, limit), limit)
          end
        chunks = Chunk.where(id: ids).includes(:document).index_by(&:id)
        ids.map { |id| chunks[id] }.compact.map { |c| { chunk: c, document: c.document, score: nil } }
      end

      def self.filtered(scope, source:, contact:, date_range:)
        scope = scope.where(source: Chunk.sources[source.to_s]) if source
        scope = scope.where(occurred_at: date_range) if date_range
        if contact
          c = contact.is_a?(Contact) ? contact : Contact.find_by(email: contact.to_s.downcase)
          return scope.none if c.nil? # unknown contact filter -> empty, not "speaker IS NULL"
          scope = scope.where(speaker_contact_id: c.id)
        end
        scope
      end

      def self.keyword_ids(scope, query, limit)
        scope.keyword_search(query).limit(limit).pluck(:id)
      end

      def self.semantic_ids(scope, query, limit)
        return [] unless scope.exists?
        vector = Embedder.embed([query], input_type: 'query')[:vectors].first
        # Constrain to corpus-eligible chunks via a SUBQUERY (scope.select(:id)), not a
        # materialized id list — keeps the wall airtight without a giant IN (...) array.
        Embedding.where(model: Embedder::MODEL, owner_type: 'Chunk', owner_id: scope.select(:id))
                 .nearest_neighbors(:embedding, vector, distance: 'cosine')
                 .limit(limit).map(&:owner_id)
      end

      def self.fuse(a, b, limit)
        scores = Hash.new(0.0)
        [a, b].each { |list| list.each_with_index { |id, i| scores[id] += 1.0 / (60 + i) } }
        scores.sort_by { |_id, s| -s }.first(limit).map(&:first)
      end
    end
  end
end
