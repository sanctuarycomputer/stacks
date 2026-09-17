#
# Full-state reconciliation between stacks Contacts and Ghost members.
# Stacks owns segmentation (labels named after enabled sources, verbatim —
# no prefix); Ghost owns opt-in state
# (newsletters) and deliverability. See
# docs/superpowers/specs/2026-07-20-ghost-contact-sync-design.md
class Stacks::GhostSync
  SOURCE_PREFIX = "g3d:ghost".freeze
  # Sources under this namespace are stacks' own record of Ghost opt-in state,
  # written by the pull leg. Deriving subscriptions from them would subscribe
  # everyone who subscribed to anything to the g3d newsletter: a consent feedback
  # loop. They are excluded from prefix derivation, always.
  # Must equal SOURCE_PREFIX: the exclusion exists precisely because the pull leg writes
  # SOURCE_PREFIX-namespaced sources. Aliased rather than repeating the literal so the two
  # cannot drift apart and silently disable the feedback-loop guard.
  EXCLUDED_SOURCE_PREFIX = SOURCE_PREFIX
  # Fixed app-wide advisory lock key for the sweep (rand of a keyboard mash;
  # any stable int works — must only avoid colliding with other app locks).
  ADVISORY_LOCK_KEY = 728534291

  # Ceiling on the per-sweep allowance reserved for already-linked contacts, so a large
  # linked population can never starve the create backfill.
  LINKED_RESERVE_CAP = 500

  def self.source_prefix(source)
    source.to_s.split(":", 2).first.to_s.downcase
  end

  def self.excluded_source?(source)
    s = source.to_s.downcase
    s == EXCLUDED_SOURCE_PREFIX || s.start_with?("#{EXCLUDED_SOURCE_PREFIX}:")
  end

  attr_reader :summary, :errors

  def initialize(ghost = Stacks::Ghost.new)
    @ghost = ghost
    @summary = Hash.new(0)
    @summary[:granted_by_newsletter] = Hash.new(0)
    @summary[:grants_planned_by_newsletter] = Hash.new(0)
    @errors = []
    @writes_remaining = 0   # fail closed until load_newsletter_config! sets the budget
    @prefix_map = {}        # so target_newsletter_ids cannot NoMethodError on nil
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
    load_newsletter_config!
    enabled = System.first_or_create!(settings: {}).ghost_synced_sources
    members = @ghost.all_members
    members_by_id = members.index_by { |m| m["id"] }
    members_by_email = members.index_by { |m| m["email"].to_s.downcase }

    # Reconcile Ghost-side deletions: any contact whose ghost_id is no longer
    # present in the fetched member list had their member deleted without a
    # webhook reaching us. Clear the link and stamp deleted_at.
    Contact.where.not(ghost_id: nil).find_each do |contact|
      next if members_by_id.key?(contact.ghost_id)
      apply_member_deleted!(contact)
      @summary[:member_deleted] += 1
    end

    # Outbound legs only run when at least one source is enabled: an empty
    # checkbox set means "sync off", not "remove every label in Ghost".
    if enabled.any?
      eligible = Contact.where("sources && ARRAY[?]::varchar[]", enabled)
      # Size the reservation to the linked population, not to a fraction of the budget.
      # A flat 50% would halve create throughput and double the 19k backfill from ~8
      # sweeps to ~16, contradicting "each sweep creates up to 2,500 members".
      linked_budget = [[eligible.synced_to_ghost.count, LINKED_RESERVE_CAP].min, 1].max

      [[eligible.synced_to_ghost, linked_budget], [eligible.not_synced_to_ghost, nil]].each do |scope, cap|
        spent_before = @summary[:writes_used]
        scope.find_each do |contact|
          break if cap && (@summary[:writes_used] - spent_before) >= cap
          capture_errors(contact) do
            next skip_invalid(contact) unless contact.email.match?(Devise.email_regexp)
            updated = sync_contact!(contact, enabled, members_by_id, members_by_email)
            if updated
              members_by_id[updated["id"]] = updated
              members_by_email[updated["email"].to_s.downcase] = updated
            end
          end
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
    wrote = false

    if member.nil?
      # Finding C: do not re-create members that were explicitly deleted.
      if contact.ghost_data.dig("snapshot", "deleted_at").present?
        @summary[:suppressed_deleted] += 1
        return nil
      end

      unless reserve_write!
        @summary[:creates_deferred] += 1
        return nil
      end

      begin
        requested_newsletter_ids = create_newsletter_ids(contact, enabled)
        member = @ghost.create_member(
          { email: contact.email, name: contact.display_name.presence, labels: desired,
            newsletters: requested_newsletter_ids.map { |id| { id: id } } }.compact
        )
        @summary[:created] += 1
        wrote = true
        confirm_granted!(contact, member, requested_newsletter_ids)
      rescue Stacks::Ghost::RequestError => e
        raise unless e.code == 422
        # Someone created this email in Ghost since our sweep snapshot — adopt it.
        # This member DOES already exist, so it runs the full existing-member decision
        # (history check included) and is gated by the grants flag like any other.
        member = @ghost.find_member_by_email(contact.email)
        raise if member.nil?
        updated = apply_grants_or_labels!(contact, member, desired, enabled)
        if updated
          member = updated
          wrote = true
        end
      end
    else
      updated = apply_grants_or_labels!(contact, member, desired, enabled)
      if updated
        member = updated
        wrote = true
      end
    end

    link_contact!(contact, member, wrote)
    member
  end

  # Inbound path for the sweep's pull leg.
  # Idempotent: only writes when something changed; source_events recorded
  # only for newly added sources.
  def upsert_contact_from_member(member)
    email = member["email"].to_s.downcase
    contact = Contact.find_by(ghost_id: member["id"]) ||
      Contact.where("LOWER(email) = ?", email).first ||
      Contact.create_or_find_by!(email: email)

    slugs = (member["newsletters"] || [])
      .map { |n| n["slug"] || newsletter_slug_map[n["id"]] }.compact.sort
    ghost_sources = slugs.any? ? slugs.map { |s| "#{SOURCE_PREFIX}:#{s}" } : [SOURCE_PREFIX]
    new_sources = ghost_sources - contact.sources

    contact.sources = (contact.sources + ghost_sources).uniq
    contact.ghost_id ||= member["id"]
    if contact.display_name.blank? && member["name"].present?
      contact.display_name = member["name"]
    end
    new_ghost_data = contact.ghost_data.merge(
      "snapshot" => {
        "newsletters" => slugs,
        "suppressed" => member.dig("email_suppression", "suppressed") || false,
        "email_disabled" => !!member["email_disabled"],
        "email_in_ghost" => (email == contact.email.downcase ? nil : member["email"]),
      }.compact
    )
    contact.ghost_data = new_ghost_data if new_ghost_data != contact.ghost_data

    # Backstop for layer 2: record that this contact is currently subscribed to
    # each newsletter, regardless of the grants flag. record_ledger_entry! is
    # write-once, so this can never downgrade an entry already marking the
    # contact as unsubscribed ("history") -- it only ever fills in the gap for
    # newsletters we have not yet observed either way.
    (member["newsletters"] || []).map { |n| n["id"] }.compact.each do |newsletter_id|
      contact.record_ledger_entry!(newsletter_id, "observed", member_id: member["id"])
    end

    contact.save! if contact.changed?
    contact.record_source_events!(new_sources)
    contact
  end

  # Resolves a contact's enabled, mapped sources into the Ghost newsletter ids
  # it should be subscribed to. Excludes the g3d:ghost namespace (see
  # EXCLUDED_SOURCE_PREFIX) so the pull leg's own record of opt-in state can
  # never feed back into itself.
  def target_newsletter_ids(contact, enabled)
    (contact.sources & enabled)
      .reject { |s| self.class.excluded_source?(s) }
      .map { |s| @prefix_map[self.class.source_prefix(s)] }
      .compact.uniq
  end

  # Decision steps 1, 2, 3, 4, 5 and 6. Returns the newsletter ids this member has
  # provably never been subscribed to. Writes observed/history ledger entries in
  # memory; the caller persists them.
  #
  # The layer-3 read is deliberately NOT memoized across an API call. A candidate
  # is by definition not currently subscribed, so re-checking "is subscribed" in
  # the apply phase cannot disqualify one: only a fresh history read can.
  def grant_candidates_for(contact, member, enabled, count: true)
    targets = target_newsletter_ids(contact, enabled)
    return [] if targets.empty?

    current_ids = (member["newsletters"] || []).map { |n| n["id"] }.compact
    ledger_applies = contact.ledger_member_id.nil? || contact.ledger_member_id == member["id"]

    undeliverable = member.dig("email_suppression", "suppressed") || member["email_disabled"]
    candidates = []
    events = nil

    targets.each do |newsletter_id|
      # Step 1 runs before step 3 on purpose: a suppressed member still gets observed
      # entries for what they ARE subscribed to, which is the population most likely to
      # unsubscribe next.
      if current_ids.include?(newsletter_id)
        contact.record_ledger_entry!(newsletter_id, "observed", member_id: member["id"])
        next
      end

      if undeliverable
        @summary[:grant_skipped_undeliverable] += 1
        next
      end

      if ledger_applies && contact.ledger_has?(newsletter_id)
        if count
          if contact.ledger_state(newsletter_id) == "history"
            @summary[:unsubscribe_respected] += 1
          else
            @summary[:already_handled] += 1
          end
        end
        next
      end

      # Step 4: the budget check comes before the history read, so a deferred member
      # costs zero API calls, not one. A planned grant (grants flag off) consumes budget
      # exactly as a real one does, so a dry-run sweep previews the same shape and API
      # cost as the real run it stands in for.
      unless writes_available?
        @summary[:grants_deferred] += 1
        return candidates
      end

      begin
        events ||= @ghost.newsletter_events_for(member["id"], current_newsletter_ids: current_ids)
      rescue Stacks::Ghost::UntrustworthyHistory, Stacks::Ghost::RequestError => e
        # Fail closed: no grants for this member this sweep. Any "observed" entry already
        # recorded for an earlier target stands, which is fine: observed only ever blocks
        # a future grant, it never permits one.
        @summary[:grant_errors] += 1
        @errors << "#{contact.email}: history unreadable: #{e.class}: #{e.message}"
        return []
      end

      if events.any? { |ev| ev.dig("data", "newsletter_id") == newsletter_id }
        contact.record_ledger_entry!(newsletter_id, "history", member_id: member["id"])
        # Always counted, unlike the ledger fast-path above: reaching this line means no
        # ledger entry existed yet, so this can only be a first-time discovery (either the
        # decision-phase's own first look, or a race that lands between decision and the
        # PUT) -- never a recount of something the decision phase already tallied.
        @summary[:unsubscribe_respected] += 1
        next
      end

      candidates << newsletter_id
    end

    candidates
  end

  private

  # One unit per Ghost member mutation, not per newsletter: a contact with two
  # candidates is a single PUT. Deferral is always safe, because it never grants
  # and never writes a ledger entry.
  def writes_available?
    @writes_remaining > 0
  end

  def reserve_write!
    return false unless writes_available?
    @writes_remaining -= 1
    @summary[:writes_used] += 1
    true
  end

  # One /newsletters/ fetch per sweep, shared by the push leg's prefix-map validation
  # (load_newsletter_config!) and the pull leg's slug resolution. Keep the RAW list here:
  # the slug map needs archived newsletters too, the prefix map does not.
  def all_newsletters
    @all_newsletters ||= @ghost.all_newsletters
  end

  def newsletter_slug_map
    @newsletter_slug_map ||= all_newsletters.each_with_object({}) { |n, map| map[n["id"]] = n["slug"] }
  end

  # Read settings fresh every sweep. System.instance memoizes in a class variable
  # that is never invalidated, so a setting saved in one puma worker is invisible
  # to another forever, and the admin "Sync Now" button runs this in a web dyno.
  def load_newsletter_config!
    system = System.first_or_create!(settings: {})
    @grants_enabled = system.ghost_newsletter_grants_enabled?
    @writes_remaining = system.ghost_sweep_write_budget_clamped
    requested = system.ghost_newsletter_prefix_map_clean

    if requested.empty?
      @prefix_map = {}
      return @prefix_map
    end

    # Degrade rather than abort. Before this, /newsletters/ was only touched from inside
    # upsert_contact_from_member, which runs under capture_errors, so an outage became
    # per-contact error lines and the deletion and label legs still completed. As the
    # first statement in sync_all! an exception would kill all of them. Fail closed on
    # GRANTS only: an empty prefix map means no grants, which is the safe posture, while
    # labels and deletion reconciliation carry on.
    fetched = begin
      all_newsletters
    rescue => e
      @errors << "newsletter config: #{e.class}: #{e.message}"
      @summary[:grant_config_unavailable] += 1
      @prefix_map = {}
      return @prefix_map
    end

    active_ids = fetched.select { |n| n["status"] == "active" }.map { |n| n["id"] }.to_set
    @prefix_map = requested.select { |_, id| active_ids.include?(id) }
    @summary[:grant_mapping_invalid] += (requested.length - @prefix_map.length)
    @prefix_map
  end

  # Severs a Ghost member link: clears ghost_id and stamps snapshot.deleted_at
  # while preserving other snapshot keys. Called by the sweep's deletion
  # reconciliation leg.
  def apply_member_deleted!(contact)
    contact.update!(
      ghost_id: nil,
      ghost_data: contact.ghost_data.merge(
        "snapshot" => (contact.ghost_data["snapshot"] || {})
          .merge("deleted_at" => Time.current.iso8601)
      )
    )
  end

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
    enabled_downcased = enabled.map(&:downcase)
    label_names(member).select { |n| enabled_downcased.include?(n.downcase) }.sort
  end

  # Pure: computes the attrs a label-only write would send, or nil for a no-op.
  # Labels are full-replace in Ghost, so always resend the preserved
  # (unmanaged) labels alongside ours. Never includes :newsletters.
  # Issues no request, so the grant path can recompute the diff against a fresh
  # member and fold it into a single PUT.
  def label_attrs_for(contact, member, desired, enabled)
    attrs = {}
    # Compare case-insensitively: Ghost dedupes labels by slug so it may store
    # "newsletter" even when the enabled source is named "Newsletter".
    # We converge when the downcased sets match; we still SEND the verbatim
    # desired names so the source name is the write contract.
    # uniq both sides: Ghost stores one label per slug, so two enabled sources
    # differing only by case can never both appear on the member — without
    # uniq that mismatch would re-PUT every sweep forever.
    if managed_label_names(member, enabled).map(&:downcase).uniq.sort != desired.map(&:downcase).uniq.sort
      enabled_downcased = enabled.map(&:downcase)
      preserved = label_names(member).reject { |n| enabled_downcased.include?(n.downcase) }
      attrs[:labels] = preserved + desired
    end
    if member["name"].blank? && contact.display_name.present?
      attrs[:name] = contact.display_name
    end
    attrs.presence
  end

  # Returns the updated member hash when a write happened, nil for a no-op.
  def update_member_labels(contact, member, desired, enabled)
    attrs = label_attrs_for(contact, member, desired, enabled)
    return nil if attrs.nil?
    unless reserve_write!
      @summary[:updates_deferred] += 1
      return nil
    end

    updated = @ghost.update_member(member["id"], attrs)
    @summary[:updated] += 1
    updated
  end

  # Targets minus anything already in the ledger. A create cannot violate the
  # invariant (no member means no history), so it is NOT gated by the flag: that
  # is what makes the index backfill a single pass.
  def create_newsletter_ids(contact, enabled)
    target_newsletter_ids(contact, enabled) - contact.newsletter_ledger_entries.keys
  end

  # Write granted only for what the response confirms AND what we actually asked for.
  # Ghost's subscribe_on_signup can attach newsletters we never requested; recording
  # those as "granted" would both inflate the number rollout step 7 compares against
  # grants_planned and permanently block a future legitimate grant, since ledger
  # entries are write-once with no repair path.
  def confirm_granted!(contact, member, requested)
    confirmed = (member["newsletters"] || []).map { |n| n["id"] }.compact
    (confirmed & requested).each do |id|
      contact.record_ledger_entry!(id, "granted", member_id: member["id"])
      @summary[:granted_on_create] += 1
      @summary[:granted_by_newsletter][id] += 1
    end
    (confirmed - requested).each do |id|
      contact.record_ledger_entry!(id, "observed", member_id: member["id"])
    end
  end

  # One PUT per contact. When there are candidates we must re-read the member and
  # its history immediately before writing, then recompute the label diff against
  # that fresh member so both ride in a single write.
  def apply_grants_or_labels!(contact, member, desired, enabled)
    # A case-fold duplicate resolves to another Contact's member via members_by_email
    # while carrying ghost_id: nil and an empty ledger, which structurally disables
    # layer 2 for it. Guard on who OWNS the member, not on this contact's ghost_id:
    # checking `contact.ghost_id.present?` would never fire, because the case we are
    # defending against is precisely the one where it is nil.
    # No write at all, labels included: the member is owned by another Contact row,
    # so a label full-replace here would just race that owner's own label sync.
    # dedupe! resolves this contact into its owner on a later run; until then it
    # drives no Ghost write whatsoever.
    if contact.ghost_id.nil? &&
       Contact.where(ghost_id: member["id"]).where.not(id: contact.id).exists?
      @summary[:writes_skipped_unlinked] += 1
      return nil
    end

    candidates = grant_candidates_for(contact, member, enabled)

    if candidates.empty?
      return update_member_labels(contact, member, desired, enabled)
    end

    unless @grants_enabled
      # A planned grant consumes budget exactly as a real one does: otherwise a dry-run
      # sweep would preview a different shape (and a different API cost) than the real
      # run it stands in for. grant_candidates_for's step 4 already confirmed a unit was
      # available moments ago, so this reserve always succeeds here; the guard just keeps
      # this site symmetric with the real grant PUT below.
      return update_member_labels(contact, member, desired, enabled) unless reserve_write!
      @summary[:grants_planned] += candidates.length
      candidates.each { |id| @summary[:grants_planned_by_newsletter][id] += 1 }
      return update_member_labels(contact, member, desired, enabled)
    end

    fresh = @ghost.find_member(member["id"])
    return update_member_labels(contact, member, desired, enabled) if fresh.nil?
    # Never write newsletters against a member we did not ask for: grant_candidates_for
    # would compute ledger_applies = false for it, disabling layer 2 entirely.
    unless fresh["id"] == member["id"]
      return update_member_labels(contact, member, desired, enabled)
    end

    # count: false - the decision-phase call already counted these; recounting would
    # double every unsubscribe_respected / already_handled that rollout step 6 reviews.
    candidates = grant_candidates_for(contact, fresh, enabled, count: false)
    return update_member_labels(contact, fresh, desired, enabled) if candidates.empty?

    current_ids = (fresh["newsletters"] || []).map { |n| n["id"] }.compact
    attrs = label_attrs_for(contact, fresh, desired, enabled) || {}
    attrs[:newsletters] = (current_ids | candidates).map { |id| { id: id } }

    return update_member_labels(contact, fresh, desired, enabled) unless reserve_write!

    updated = @ghost.update_member(fresh["id"], attrs)
    @summary[:updated] += 1
    # A 2xx with an empty members array yields nil. update_member_labels already
    # tolerates that; degrade the same way rather than raising and losing link_contact!
    # (and with it this contact's in-memory ledger entries).
    return fresh if updated.nil?

    confirmed = (updated["newsletters"] || []).map { |n| n["id"] }.compact
    candidates.each do |id|
      next unless confirmed.include?(id)
      contact.record_ledger_entry!(id, "granted", member_id: fresh["id"])
      @summary[:granted] += 1
      @summary[:granted_by_newsletter][id] += 1
    end
    updated
  end

  def delabel_member!(contact, member, enabled)
    return member if managed_label_names(member, enabled).empty?
    unless reserve_write!
      @summary[:updates_deferred] += 1
      return member
    end
    enabled_downcased = enabled.map(&:downcase)
    updated = @ghost.update_member(
      member["id"],
      labels: label_names(member).reject { |n| enabled_downcased.include?(n.downcase) }
    )
    @summary[:delabeled] += 1
    updated
  end

  # Finding A: only stamp synced_at when a real Ghost write occurred (wrote=true).
  # Skip the update entirely when ghost_id already matches, nothing was written to
  # Ghost, AND the in-memory ledger carries no unsaved entry. A pre-write history
  # read (layer 3, or the pre-PUT recheck) can record a "history"/"observed" ledger
  # entry in memory even when the Ghost write it was guarding turns out to be a
  # no-op or gets skipped entirely -- without this check that entry would evaporate
  # unsaved, and the next sweep would re-roll the same history read forever.
  def link_contact!(contact, member, wrote = false)
    already_linked = contact.ghost_id == member["id"]
    ledger_dirty = contact.changed.include?("ghost_data")
    return if already_linked && !wrote && !ledger_dirty

    new_data = wrote ? contact.ghost_data.merge("synced_at" => Time.current.iso8601) : contact.ghost_data
    contact.update!(ghost_id: member["id"], ghost_data: new_data)
  rescue ActiveRecord::RecordNotUnique
    # Member already linked to another contact (its email was changed in
    # Ghost). Email is stacks-owned: if the member's email now matches THIS
    # contact, steal the link from the stale owner; otherwise leave it.
    owner = Contact.where(ghost_id: member["id"]).where.not(id: contact.id).first
    if owner && member["email"].to_s.downcase == contact.email.downcase
      # Skip the steal when the current owner's email is a case-fold duplicate of
      # this contact's email: stealing would just ping-pong the link every sweep.
      # dedupe! will collapse them later (and fix #1 will carry the link through).
      if owner.email.downcase == contact.email.downcase
        @summary[:link_conflicts] += 1
        return
      end
      owner.update!(ghost_id: nil)
      new_data = wrote ? contact.ghost_data.merge("synced_at" => Time.current.iso8601) : contact.ghost_data
      contact.update!(ghost_id: member["id"], ghost_data: new_data)
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
