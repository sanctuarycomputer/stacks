class Document < ApplicationRecord
  belongs_to :source_record, polymorphic: true, optional: true
  has_many :chunks, dependent: :destroy
  has_many :document_contacts, dependent: :destroy
  has_many :contacts, through: :document_contacts

  enum source: { meet: 0 }
  enum excluded: { not_excluded: 0, auto_excluded: 1, manually_excluded: 2, manually_included: 3 }
  enum excluded_reason: {
    none: 0, one_on_one: 1, performance_review: 2, compensation: 3,
    hr: 4, offboarding: 5, pip: 6, title_keyword: 7, manual: 8
  }, _prefix: :reason

  scope :corpus_eligible, -> { where(excluded: [excludeds[:not_excluded], excludeds[:manually_included]]) }

  def corpus_eligible?
    not_excluded? || manually_included?
  end

  def human_locked?
    manually_excluded? || manually_included?
  end
end
