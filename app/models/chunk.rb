class Chunk < ApplicationRecord
  belongs_to :document
  belongs_to :speaker_contact, class_name: 'Contact', optional: true
  has_many :mentions, dependent: :destroy
  has_one :embedding, as: :owner, dependent: :destroy

  enum source: { meet: 0 }

  scope :keyword_search, ->(query) {
    where('content_tsv @@ plainto_tsquery(:q)', q: query)
      .order(Arel.sql("ts_rank(content_tsv, plainto_tsquery(#{connection.quote(query)})) DESC"))
  }
  scope :corpus_eligible, -> { joins(:document).merge(Document.corpus_eligible) }
end
