#
# Full-state reconciliation between stacks Contacts and Ghost members.
# Stacks owns segmentation (labels named after enabled sources, verbatim —
# no prefix); Ghost owns opt-in state
# (newsletters) and deliverability. See
# docs/superpowers/specs/2026-07-20-ghost-contact-sync-design.md
class Stacks::GhostSync
  SOURCE_PREFIX = "g3d:ghost".freeze
  # Fixed app-wide advisory lock key for the sweep (rand of a keyboard mash;
  # any stable int works — must only avoid colliding with other app locks).
  ADVISORY_LOCK_KEY = 728534291

  attr_reader :summary, :errors

  def initialize(ghost = Stacks::Ghost.new)
    @ghost = ghost
    @summary = Hash.new(0)
    @errors = []
  end

  # Wraps the sweep in a pg advisory lock so an overlapping Scheduler run or
  # admin-button click exits cleanly instead of double-writing. Returns the
  # sync (for summary/errors), or nil when another run holds the lock.
  def self.sync_all_with_lock!(ghost = Stacks::Ghost.new)
    conn = ActiveRecord::Base.connection
    got_lock = conn.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    return nil unless got_lock

    begin
      sync = new(ghost)
      sync.sync_all!
      sync
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
    end
  end

  def sync_all!
    enabled = GhostSyncedSource.pluck(:source)
    members = @ghost.all_members
    members_by_id = members.index_by { |m| m["id"] }
    members_by_email = members.index_by { |m| m["email"].to_s.downcase }

    # Outbound legs only run when at least one source is enabled: an empty
    # checkbox set means "sync off", not "remove every label in Ghost".
    if enabled.any?
      Contact.where("sources && ARRAY[?]::varchar[]", enabled).find_each do |contact|
        capture_errors(contact) do
          next skip_invalid(contact) unless contact.email.match?(Devise.email_regexp)
          updated = sync_contact!(contact, enabled, members_by_id, members_by_email)
          members_by_id[updated["id"]] = updated if updated
        end
      end

      Contact.where.not(ghost_id: nil)
        .where.not("sources && ARRAY[?]::varchar[]", enabled)
        .find_each do |contact|
          capture_errors(contact) do
            member = members_by_id[contact.ghost_id]
            next unless member
            members_by_id[member["id"]] = delabel_member!(contact, member, enabled)
          end
        end
    end

    pull_members!(members_by_id.values)
    summary
  end

  def sync_contact!(contact, enabled, members_by_id, members_by_email)
    desired = desired_labels_for(contact, enabled)
    member = members_by_id[contact.ghost_id] || members_by_email[contact.email.downcase]

    if member.nil?
      begin
        member = @ghost.create_member(
          { email: contact.email, name: contact.display_name.presence, labels: desired }.compact
        )
        @summary[:created] += 1
      rescue Stacks::Ghost::RequestError => e
        raise unless e.code == 422
        # Someone created this email in Ghost since our sweep snapshot — adopt it.
        member = @ghost.find_member_by_email(contact.email)
        raise if member.nil?
        member = update_member_labels(contact, member, desired, enabled) || member
      end
    else
      member = update_member_labels(contact, member, desired, enabled) || member
    end

    link_contact!(contact, member)
    member
  end

  # Shared inbound path for the sweep's pull leg and the webhook receiver.
  # Idempotent: only writes when something changed; source_events recorded
  # only for newly added sources — this is also our echo suppression, since
  # the webhook fired by our own outbound label write finds nothing to do.
  def upsert_contact_from_member(member)
    email = member["email"].to_s.downcase
    contact = Contact.find_by(ghost_id: member["id"]) ||
      Contact.where("LOWER(email) = ?", email).first ||
      Contact.create_or_find_by!(email: email)

    slugs = (member["newsletters"] || []).map { |n| n["slug"] }.compact.sort
    ghost_sources = slugs.any? ? slugs.map { |s| "#{SOURCE_PREFIX}:#{s}" } : [SOURCE_PREFIX]
    new_sources = ghost_sources - contact.sources

    contact.sources = (contact.sources + ghost_sources).uniq
    contact.ghost_id ||= member["id"]
    if contact.display_name.blank? && member["name"].present?
      contact.display_name = member["name"]
    end
    contact.ghost_data = contact.ghost_data.merge(
      "snapshot" => {
        "newsletters" => slugs,
        "suppressed" => member.dig("email_suppression", "suppressed") || false,
        "email_disabled" => !!member["email_disabled"],
        "email_in_ghost" => (email == contact.email.downcase ? nil : member["email"]),
      }.compact
    )
    contact.save! if contact.changed?
    contact.record_source_events!(new_sources)
    contact
  end

  # member.deleted: keep the contact (funnel history), sever the link.
  def handle_member_deleted(previous_member)
    contact = Contact.find_by(ghost_id: previous_member["id"])
    return nil unless contact

    contact.update!(
      ghost_id: nil,
      ghost_data: contact.ghost_data.merge(
        "snapshot" => (contact.ghost_data["snapshot"] || {})
          .merge("deleted_at" => Time.current.iso8601)
      )
    )
    contact
  end

  private

  # Labels are source names verbatim; the managed label set is exactly the
  # enabled sources. Labels outside that set (hand-added in Ghost, or from a
  # since-unchecked source) are never touched.
  def desired_labels_for(contact, enabled)
    (contact.sources & enabled).sort
  end

  def label_names(member)
    (member["labels"] || []).map { |l| l["name"] }
  end

  def managed_label_names(member, enabled)
    (label_names(member) & enabled).sort
  end

  # Returns the updated member hash when a write happened, nil for a no-op.
  # Labels are full-replace in Ghost, so always resend the preserved
  # (unmanaged) labels alongside ours. Never includes :newsletters.
  def update_member_labels(contact, member, desired, enabled)
    attrs = {}
    if managed_label_names(member, enabled) != desired
      attrs[:labels] = (label_names(member) - enabled) + desired
    end
    if member["name"].blank? && contact.display_name.present?
      attrs[:name] = contact.display_name
    end
    return nil if attrs.empty?

    updated = @ghost.update_member(member["id"], attrs)
    @summary[:updated] += 1
    updated
  end

  def delabel_member!(contact, member, enabled)
    return member if managed_label_names(member, enabled).empty?
    updated = @ghost.update_member(member["id"], labels: label_names(member) - enabled)
    @summary[:delabeled] += 1
    updated
  end

  def link_contact!(contact, member)
    contact.update!(
      ghost_id: member["id"],
      ghost_data: contact.ghost_data.merge("synced_at" => Time.current.iso8601)
    )
  rescue ActiveRecord::RecordNotUnique
    # Member already linked to another contact (its email was changed in
    # Ghost). Email is stacks-owned: if the member's email now matches THIS
    # contact, steal the link from the stale owner; otherwise leave it.
    owner = Contact.where(ghost_id: member["id"]).where.not(id: contact.id).first
    if owner && member["email"].to_s.downcase == contact.email.downcase
      owner.update!(ghost_id: nil)
      contact.update!(
        ghost_id: member["id"],
        ghost_data: contact.ghost_data.merge("synced_at" => Time.current.iso8601)
      )
    else
      @summary[:link_conflicts] += 1
    end
  end

  def skip_invalid(_contact)
    @summary[:skipped_invalid] += 1
    nil
  end

  def capture_errors(contact)
    yield
  rescue => e
    @summary[:errors] += 1
    @errors << "#{contact.email}: #{e.class}: #{e.message}"
  end

  # Reconciliation for missed webhooks: every Ghost member flows through the
  # shared upsert, so organic signups land in the funnel even if their
  # webhook was dropped (Ghost has a 2s timeout and no retries).
  def pull_members!(members)
    members.each do |member|
      contact = Contact.find_by(ghost_id: member["id"])
      begin
        upserted = upsert_contact_from_member(member)
        @summary[:pulled] += 1 if contact.nil? && upserted.ghost_id == member["id"]
      rescue => e
        @summary[:errors] += 1
        @errors << "#{member["email"]}: #{e.class}: #{e.message}"
      end
    end
  end
end
