class Contact < ApplicationRecord
  validates :email, format: { with: Devise.email_regexp }

  scope :synced_to_apollo, -> {
    where.not(apollo_id: nil)
  }
  scope :not_synced_to_apollo, -> {
    where(apollo_id: nil)
  }

  scope :address_cont, ->(value) { where_address_contains(value) }
  scope :sources_cont, ->(value) { where("array_to_string(sources, ' ') ILIKE ?", "%#{value}%") }

  def self.ransackable_attributes(auth_object = nil)
    super - %w[sources metadata]
  end

  def self.ransackable_scopes(*)
    %i(address_cont sources_cont)
  end

  def self.where_address_contains(value)
    self.where("apollo_data ->> 'present_raw_address' LIKE :value", value: "%#{value}%")
  end

  def apollo_link
    "https://app.apollo.io/#/contacts/#{apollo_id}"
  end

  def sync_to_apollo!(apollo = Stacks::Apollo.new)
    existing_contacts = apollo.search_by_email(self.email) || []
    apollo_contact = existing_contacts.first || apollo.create_contact(self.email)
    return unless apollo_contact.present?

    if (apollo_contact.dig("email") || "").downcase == self.email.downcase
      begin
        self.update(apollo_id: apollo_contact["id"], apollo_data: apollo_contact)
      rescue ActiveRecord::RecordNotUnique => e
        if existing_contact = Contact.find_by(apollo_id: apollo_contact["id"])
          self.sources = [*self.sources, *existing_contact.sources].uniq
          existing_contact.destroy!
          puts "~~~> will retry for #{self.email}"
          retry
        else
          raise e
        end
      end
    end
  end

  # Returns the Contact for an email (creating it if needed), or nil when the email is
  # blank/malformed. Returning nil (rather than raising) keeps a single bad attendee
  # email from aborting a whole meeting's ingest — callers treat nil as "unresolved".
  def self.resolve_email(email, name: nil)
    normalized = email.to_s.downcase.strip
    return nil unless normalized.match?(Devise.email_regexp)
    contact = create_or_find_by!(email: normalized)
    contact.sources = (contact.sources + ['etl:meet']).uniq
    contact.display_name = name if contact.display_name.blank? && name.present?
    contact.save! if contact.changed?
    contact
  end

  # Tables that reference contacts.id and must be repointed at the surviving
  # record before any duplicate is destroyed. Without this, delete_all trips the
  # foreign key constraints (e.g. document_contacts.fk_rails_edc7f9ba3b).
  # Format: [table, foreign key column, [columns forming a uniqueness scope]].
  # The uniqueness scope prevents violating a unique index when repointing
  # (e.g. document_contacts is unique on [document_id, contact_id, role]).
  CONTACT_REFERENCES = [
    ["document_contacts",             "contact_id",         %w[document_id role]],
    ["meeting_participants",          "contact_id",         nil],
    ["mentions",                      "contact_id",         nil],
    ["chunks",                        "speaker_contact_id", nil],
    ["meeting_transcript_segments",   "speaker_contact_id", nil],
  ].freeze

  def dedupe!
    self.update(sources: self.sources.uniq)

    dupes = Contact
      .where("LOWER(email) = ?", email.downcase)
      .order(:id)
      .to_a
    return self unless dupes.length > 1

    survivor = dupes.first
    losers = dupes[1..]

    merged_sources = dupes.flat_map(&:sources).compact.uniq
    merged_apollo_id = dupes.map(&:apollo_id).compact.first
    merged_display_name = dupes.map(&:display_name).compact.first

    ActiveRecord::Base.transaction do
      losers.each do |loser|
        CONTACT_REFERENCES.each do |table, fk, scope_cols|
          repoint_references!(table, fk, scope_cols, from: loser.id, to: survivor.id)
        end
      end

      # Delete the losers BEFORE reassigning their attributes onto the survivor.
      # contacts.apollo_id has a unique index, so assigning a loser's apollo_id to
      # the survivor while that loser still exists would violate the constraint.
      Contact.where(id: losers.map(&:id)).delete_all

      survivor.update!(
        sources: merged_sources,
        apollo_id: merged_apollo_id,
        display_name: survivor.display_name.presence || merged_display_name,
      )
    end

    survivor.reload
  end

  private

  # Repoint every referencing row from `from` to `to`. When a uniqueness scope is
  # given, rows whose (scope + to) already exist on the survivor are deleted
  # instead of updated, so we never collide with a unique index.
  def repoint_references!(table, fk, scope_cols, from:, to:)
    conn = self.class.connection
    quoted_table = conn.quote_table_name(table)
    quoted_fk = conn.quote_column_name(fk)

    if scope_cols.present?
      quoted_scope = scope_cols.map { |c| conn.quote_column_name(c) }
      join_on = quoted_scope.map { |c| "dst.#{c} = src.#{c}" }.join(" AND ")

      # Drop losers' rows that would duplicate an existing survivor row.
      conn.execute(<<~SQL)
        DELETE FROM #{quoted_table} src
        USING #{quoted_table} dst
        WHERE src.#{quoted_fk} = #{conn.quote(from)}
          AND dst.#{quoted_fk} = #{conn.quote(to)}
          AND #{join_on}
      SQL
    end

    conn.execute(<<~SQL)
      UPDATE #{quoted_table}
      SET #{quoted_fk} = #{conn.quote(to)}
      WHERE #{quoted_fk} = #{conn.quote(from)}
    SQL
  end
end
