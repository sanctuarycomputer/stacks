class Document < ApplicationRecord
  belongs_to :source_record, polymorphic: true, optional: true
  has_many :chunks, dependent: :destroy
  has_many :document_contacts, dependent: :destroy
  has_many :contacts, through: :document_contacts
  has_many :weekly_ships, dependent: :destroy

  enum source: { meet: 0, gemini_notes: 1, google_groups: 2 }
  enum excluded: { not_excluded: 0, auto_excluded: 1, manually_excluded: 2, manually_included: 3 }
  enum excluded_reason: {
    none: 0, one_on_one: 1, performance_review: 2, compensation: 3,
    hr: 4, offboarding: 5, pip: 6, title_keyword: 7, manual: 8
  }, _prefix: :reason

  SHIPS_GROUP_EMAIL = "ships@sanctuary.computer".freeze

  scope :corpus_eligible, -> { where(excluded: [excludeds[:not_excluded], excludeds[:manually_included]]) }

  scope :ships_group, -> {
    where(source: :google_groups).where("raw_metadata->>'group_email' = ?", SHIPS_GROUP_EMAIL)
  }

  # The Meet document that already represents a given Google Drive transcript, regardless
  # of which source ingested it: the Drive sync keys it as external_id; the Meet API sync
  # keys itself on the conference-record id and records the Drive doc id in raw_metadata.
  # Owning the key (and its two storage shapes) here keeps the Drive<->API dedup in one
  # place instead of duplicating the JSON path across both sources.
  #
  # NOTE: BOTH sources store drive_doc_id in raw_metadata, so a source's OWN row matches
  # this scope. A caller using it to dedup against the OTHER source must exclude its own
  # row with `.where.not(external_id: <its external_id>)`, or a re-scan skips itself.
  scope :for_drive_doc, lambda { |drive_doc_id|
    meet.where("external_id = :id OR raw_metadata->>'drive_doc_id' = :id", id: drive_doc_id)
  }

  def corpus_eligible?
    not_excluded? || manually_included?
  end

  def human_locked?
    manually_excluded? || manually_included?
  end

  # Google Groups' d/msgid redirector resolves an RFC822 Message-ID to the
  # thread in the Groups UI (click-test verified 2026-08-18). Prefer a
  # message-id known to be IN the group (gmail_message_ids.first) — thread
  # roots (external_id) are sometimes never-posted ancestors (7/242 in dev).
  def google_groups_permalink
    return nil unless google_groups?
    group = raw_metadata&.dig("group_email").presence
    return nil unless group&.include?("@")
    local, domain = group.split("@", 2)
    id = Array(raw_metadata["gmail_message_ids"]).first.presence || external_id
    return nil if id.blank?
    "https://groups.google.com/a/#{domain}/d/msgid/#{local}/#{CGI.escape(id.delete_prefix('<').delete_suffix('>'))}"
  end
end
