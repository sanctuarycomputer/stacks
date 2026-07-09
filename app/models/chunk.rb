class Chunk < ApplicationRecord
  belongs_to :document
  belongs_to :speaker_contact, class_name: 'Contact', optional: true
  has_many :mentions, dependent: :destroy
  has_one :embedding, as: :owner, dependent: :destroy

  enum source: { meet: 0, gemini_notes: 1, google_groups: 2 }

  scope :keyword_search, ->(query) {
    where("content_tsv @@ plainto_tsquery('english', :q)", q: query)
      .order(Arel.sql("ts_rank(content_tsv, plainto_tsquery('english', #{connection.quote(query)})) DESC"))
  }
  scope :corpus_eligible, -> { joins(:document).merge(Document.corpus_eligible) }
end
