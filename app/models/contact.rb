class Contact < ApplicationRecord
  validates :email, format: { with: Devise.email_regexp }

  scope :synced_to_apollo, -> {
    where.not(apollo_id: nil)
  }
  scope :not_synced_to_apollo, -> {
    where(apollo_id: nil)
  }

  scope :synced_to_ghost, -> {
    where.not(ghost_id: nil)
  }
  scope :not_synced_to_ghost, -> {
    where(ghost_id: nil)
  }

  scope :address_cont, ->(value) { where_address_contains(value) }
  scope :sources_cont, ->(value) { where("array_to_string(sources, ' ') ILIKE ?", "%#{value}%") }

  def self.ransackable_attributes(auth_object = nil)
    super - %w[sources metadata source_events]
  end

  # Unions per-source event lists ({source => [{"added_at" => ts}, ...]}),
  # keeping each list sorted by added_at, so a survivor keeps the full view
  # history when duplicate contacts merge.
  def self.merge_source_events(events_list)
    events_list.compact.each_with_object({}) do |events, acc|
      events.each do |source, entries|
        acc[source] = [*acc[source], *entries].sort_by { |e| e['added_at'].to_s }
      end
    end
  end

  # Appends { added_at: now() } to source_events[source] for every given source,
  # even when the source is already in the deduped sources array — this is the
  # view counter. jsonb_set at the SQL level so concurrent writes cannot lose events.
  def record_source_events!(sources)
    Array(sources).each do |source|
      Contact.where(id: id).update_all([
        <<~SQL.squish,
          source_events = jsonb_set(
            source_events,
            ARRAY[?],
            COALESCE(source_events->?, '[]'::jsonb)
              || jsonb_build_array(jsonb_build_object('added_at', now())),
            true
          )
        SQL
        source.to_s, source.to_s
      ])
    end
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
          # Merge from row-locked reads (id order, matching dedupe!) so a
          # concurrent source_events append isn't lost mid-merge.
          merged = false
          ActiveRecord::Base.transaction do
            locked = Contact.where(id: [id, existing_contact.id]).lock.order(:id).index_by(&:id)
            fresh_self = locked[id]
            fresh_existing = locked[existing_contact.id]
            if fresh_self
              self.sources = [*fresh_self.sources, *fresh_existing&.sources].uniq
              self.source_events = Contact.merge_source_events(
                [fresh_self.source_events, fresh_existing&.source_events]
              )
              # Carry ghost_id/ghost_data from fresh_existing when self lacks them.
              # ghost_id has a unique index — destroy fresh_existing before saving self.
              if fresh_existing
                self.ghost_id ||= fresh_existing.ghost_id
                if self.ghost_data.blank? || self.ghost_data == {}
                  self.ghost_data = fresh_existing.ghost_data
                elsif fresh_existing.ghost_data.dig("snapshot", "deleted_at").present? &&
                      self.ghost_data.dig("snapshot", "deleted_at").blank?
                  self.ghost_data = self.ghost_data.merge(
                    "snapshot" => (self.ghost_data["snapshot"] || {}).merge(
                      "deleted_at" => fresh_existing.ghost_data.dig("snapshot", "deleted_at")
                    )
                  )
                end
              end
              # Destroy before save!: self still carries the conflicting
              # apollo_id (and now potentially ghost_id), so saving first would
              # re-trip the unique index.
              fresh_existing&.destroy!
              save!
              merged = true
            end
          end
          # If our own row vanished (concurrent dedupe!), there is nothing
          # left to sync — bail rather than retrying forever.
          return unless merged
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

    dupe_ids = Contact
      .where("LOWER(email) = ?", email.downcase)
      .order(:id)
      .pluck(:id)
    return self unless dupe_ids.length > 1

    survivor = nil
    ActiveRecord::Base.transaction do
      # Row-lock the duplicates and merge from the locked reads: an API post
      # appending to a loser's source_events between an unlocked load and the
      # delete would otherwise be silently dropped.
      dupes = Contact.where(id: dupe_ids).lock.order(:id).to_a
      survivor = dupes.first

      # A concurrent dedupe! may have already merged and deleted these rows
      # between the pluck and the lock — nothing left to do here.
      if dupes.length > 1
        losers = dupes[1..]

        merged_sources = dupes.flat_map(&:sources).compact.uniq
        merged_source_events = Contact.merge_source_events(dupes.map(&:source_events))
        merged_apollo_id = dupes.map(&:apollo_id).compact.first
        merged_display_name = dupes.map(&:display_name).compact.first

        # Carry ghost_id from the first dupe that has one (ordered by id, same as
        # apollo_id). ghost_id has a unique index — delete losers before assigning.
        merged_ghost_id = dupes.map(&:ghost_id).compact.first
        # Carry ghost_data from the dupe that owns merged_ghost_id (fall back to the
        # first dupe with non-empty ghost_data, else {}).
        ghost_id_owner = dupes.find { |d| d.ghost_id == merged_ghost_id }
        merged_ghost_data = (ghost_id_owner&.ghost_data.presence || dupes.map(&:ghost_data).find(&:present?) || {}).dup
        # Opt-out must survive any merge direction: if ANY dupe has deleted_at and
        # the carried ghost_data lacks it, preserve it into the carried snapshot.
        any_deleted_at = dupes.map { |d| d.ghost_data.dig("snapshot", "deleted_at") }.compact.first
        if any_deleted_at && merged_ghost_data.dig("snapshot", "deleted_at").blank?
          merged_ghost_data["snapshot"] = (merged_ghost_data["snapshot"] || {}).merge("deleted_at" => any_deleted_at)
        end

        losers.each do |loser|
          CONTACT_REFERENCES.each do |table, fk, scope_cols|
            repoint_references!(table, fk, scope_cols, from: loser.id, to: survivor.id)
          end
        end

        # Delete the losers BEFORE reassigning their attributes onto the survivor.
        # contacts.apollo_id and contacts.ghost_id both have unique indexes, so
        # assigning a loser's value to the survivor while that loser still exists
        # would violate the constraint.
        Contact.where(id: losers.map(&:id)).delete_all

        survivor.update!(
          sources: merged_sources,
          source_events: merged_source_events,
          apollo_id: merged_apollo_id,
          display_name: survivor.display_name.presence || merged_display_name,
          ghost_id: merged_ghost_id,
          ghost_data: merged_ghost_data,
        )
      end
    end

    survivor ? survivor.reload : self
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
