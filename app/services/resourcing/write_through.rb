module Resourcing
  # Applies a projected_assignment change through to Runn, guarded so a human's
  # Runn edit can never be clobbered:
  #   - CAS: apply only if the live owned Runn assignment still equals last_synced_runn_state
  #   - provenance: only mutate an assignment we own (marker still present in note)
  #   - compensating rollback: undo a created row on a partial failure
  # Each row owns exactly ONE Runn assignment (a strict 1:1 mirror). Splitting
  # around PTO (shorten one row + add a tail row) is the caller's concern.
  class WriteThrough
    Result = Struct.new(:status, :before, :after, :runn_assignment_id, :conflict, keyword_init: true)
    class UnresolvedContributor < StandardError; end
    class UnresolvableRole < StandardError; end

    def self.provenance_marker(source_key) = "[stacksbot:#{source_key}]"

    def initialize(runn: Stacks::Runn.new(max_retries: 0))
      @runn = runn
    end

    def apply(row, preview: false, adopt_expected: nil)
      # A relinquished row is one a human took back (see the CAS block below). We
      # permanently stop managing it — never write, never re-flag.
      return Result.new(status: :noop) if row.managed_by == "relinquished"

      runn_person_id = resolver.runn_person_id_for(row.contributor)
      if runn_person_id.nil?
        raise UnresolvedContributor,
          "contributor #{row.contributor_id} has no unique active Runn person (email matched 0 or multiple)"
      end

      assignments = @runn.get_assignments

      # --- adopt: take over a human-authored assignment on a stated human directive ---
      if adopt_expected && row.runn_assignment_id.nil?
        live = assignments.find { |a| a["id"] == adopt_expected["id"] }
        return conflict(live) if live.nil?                          # target gone → human already changed it
        # adopt only takes over HUMAN (unmarked) assignments — never one stacksbot
        # already owns, which would silently orphan the owning row.
        return conflict(live) if live["note"].to_s.include?("[stacksbot:")
        # NOTE: same_state? (CAS baseline) intentionally omits `note` from the projected
        # mirror, so a human note-only edit here isn't caught — acceptable because
        # `before:` still captures the current note as revert material.
        return conflict(live) unless same_state?(live, adopt_expected) # target moved since the snapshot
        role_id = live["roleId"]
        desired = {
          "personId" => runn_person_id, "projectId" => row.runn_project_id, "roleId" => role_id,
          "startDate" => row.start_date.iso8601, "endDate" => row.end_date.iso8601,
          "minutesPerDay" => row.minutes_per_day,
        }
        return Result.new(status: :preview, before: live, after: desired) if preview
        new_hash = replace!(old_id: live["id"], desired: desired, source_key: row.source_key, note: row.note)
        row.update!(runn_assignment_id: new_hash["id"], last_synced_runn_state: new_hash)
        return Result.new(status: :applied, before: live, after: new_hash, runn_assignment_id: new_hash["id"])
      end

      current = row.runn_assignment_id && assignments.find { |a| a["id"] == row.runn_assignment_id }

      # CAS + provenance: if we think we own an assignment, it must still be ours & unchanged.
      if row.runn_assignment_id
        return conflict(current) if current.nil? # human deleted it → Decision
        return conflict(current) unless current["note"].to_s.include?(self.class.provenance_marker(row.source_key)) # human replaced it → Decision
        # human hand-edited an assignment we own (marker still present, same id, but
        # the fields drifted from what we last wrote): the human is taking it back.
        # We never undo their edit — we RELINQUISH management (yield permanently), so
        # this assignment is left exactly as they set it and never touched or re-flagged
        # again. Persist the yield (except in preview) by marking the row relinquished;
        # the top-of-apply guard then no-ops every future write to it.
        unless same_state?(current, row.last_synced_runn_state)
          row.update!(managed_by: "relinquished") unless preview
          return Result.new(status: :relinquished, before: current)
        end
      end

      role_id = current ? current["roleId"] : most_recent_role_id(runn_person_id, row.runn_project_id, assignments)
      raise UnresolvableRole, "no Runn role for contributor #{row.contributor_id}" if role_id.nil?

      desired = {
        "personId" => runn_person_id, "projectId" => row.runn_project_id, "roleId" => role_id,
        "startDate" => row.start_date.iso8601, "endDate" => row.end_date.iso8601,
        "minutesPerDay" => row.minutes_per_day,
      }
      if current && same_state?(current, desired)
        return Result.new(status: :noop, before: current, after: current, runn_assignment_id: row.runn_assignment_id)
      end
      return Result.new(status: :preview, before: current, after: desired) if preview

      new_hash = replace!(old_id: row.runn_assignment_id, desired: desired, source_key: row.source_key, note: row.note)
      row.update!(runn_assignment_id: new_hash["id"], last_synced_runn_state: new_hash)
      Result.new(status: :applied, before: current, after: new_hash, runn_assignment_id: new_hash["id"])
    end

    # Adopts ONE human-authored Runn assignment into N stacksbot-owned
    # projected_assignment rows, as a single atomic operation.
    #
    # Emitting N independent apply(adopt_expected:) calls for one human is
    # unsafe: the first adopt deletes the human assignment and creates
    # segment 1's replacement; every subsequent adopt then finds the target
    # already gone and conflicts (or, worse, races another human edit into
    # the gap) — data loss on segments 2..N. adopt_into instead treats the
    # split as one unit: validate the WHOLE group against the live human
    # snapshot up front (zero writes if any guard fails), then create every
    # replacement assignment FIRST, and only once ALL creates have
    # succeeded delete the original human assignment ONCE. Ordering matters
    # for the rollback story:
    #   - a create fails partway through  → roll back every create so far,
    #     the human assignment is never touched, re-raise.
    #   - all creates succeed but the single delete fails → roll back EVERY
    #     created assignment (total rollback), the human assignment survives
    #     untouched, re-raise.
    # Either way, a failure anywhere leaves Runn exactly as it was before
    # the call — never a half-adopted mess with some segments live and
    # others missing.
    #
    # Rows that already own a Runn assignment are routed through the
    # ordinary apply() path (no adopt) instead of group_adopt — this is
    # what makes re-running adopt_into after a prior success a no-op rather
    # than a re-adopt attempt against an already-consumed human assignment.
    def adopt_into(rows:, adopt_expected:, preview: false)
      owned, fresh = rows.partition(&:runn_assignment_id)
      by_key = {}
      owned.each { |r| by_key[r.source_key] = apply(r, preview: preview) }
      by_key.merge!(group_adopt(fresh, adopt_expected, preview)) if fresh.any?
      rows.map { |r| by_key[r.source_key] }
    end

    # DELETE ?archive_runn=true — remove the owned Runn assignment, CAS-guarded.
    # Does NOT mutate/destroy the row — the caller destroys it only on non-conflict.
    def archive(row)
      return Result.new(status: :noop) if row.managed_by == "relinquished" # yielded to a human — never touch
      return Result.new(status: :noop) if row.runn_assignment_id.nil?

      current = @runn.get_assignments.find { |a| a["id"] == row.runn_assignment_id }
      return conflict(current) if current.nil?
      return conflict(current) unless current["note"].to_s.include?(self.class.provenance_marker(row.source_key))
      return conflict(current) unless same_state?(current, row.last_synced_runn_state)

      Mcp::WriteGuard.check!
      @runn.delete_assignment(row.runn_assignment_id)
      Result.new(status: :applied, before: current, after: nil)
    end

    private

    # One resolver per WriteThrough so its people list is fetched once and reused
    # across every apply in a shared request/batch (see RunnPersonResolver#people).
    def resolver
      @resolver ||= RunnPersonResolver.new(@runn)
    end

    # create the (shorter/new) assignment first, then delete the old — rollback the create on failure.
    def replace!(old_id:, desired:, source_key:, note: nil)
      Mcp::WriteGuard.check!
      created = @runn.create_assignment(
        person_id: desired["personId"], project_id: desired["projectId"], role_id: desired["roleId"],
        start_date: desired["startDate"], end_date: desired["endDate"],
        minutes_per_day: desired["minutesPerDay"], note: provenance_note(source_key, note)
      )
      new_hash = normalize_created(created, desired, source_key, note)
      begin
        if old_id
          Mcp::WriteGuard.check!
          @runn.delete_assignment(old_id)
        end
      rescue StandardError => e
        # Not transactional: if this delete times out client-side after actually
        # succeeding server-side, this compensating delete of the new assignment can
        # itself fail/race, leaving the row's runn_assignment_id stale and every future
        # apply() reading a conflict until a human reconciles it.
        @runn.delete_assignment(new_hash["id"]) rescue nil # compensating rollback
        raise e
      end
      new_hash
    end

    # Runn create returns a bare Hash OR an array of segments; we expect exactly one here
    # (no native leave → no auto-split). Take the first, stamp the fields we sent.
    def normalize_created(resp, desired, source_key, note = nil)
      row = resp.is_a?(Array) ? resp.first : resp
      id = row.is_a?(Hash) ? row["id"] : row
      desired.merge("id" => id, "note" => provenance_note(source_key, note))
    end

    def provenance_note(source_key, note)
      marker = self.class.provenance_marker(source_key)
      note.present? ? "#{marker} #{note}" : marker
    end

    # most-recent (by endDate) role for this person, preferring an assignment on the
    # SAME project (so a new create can't stamp another project's rate), falling back
    # to the person's most-recent role across any project. Templates are excluded —
    # they aren't real billing history.
    def most_recent_role_id(runn_person_id, project_id, assignments)
      person = assignments.reject { |a| a["isTemplate"] }.select { |a| a["personId"] == runn_person_id }
      pool = person.select { |a| a["projectId"] == project_id }
      pool = person if pool.empty?
      pool.max_by { |a| a["endDate"].to_s }&.dig("roleId")
    end

    # CAS baseline compare (ignore id/note): person/project/role/dates/minutes
    def same_state?(a, b) = state_key(a) == state_key(b)

    # tolerant of Runn returning dates as either "2030-05-01" or a full
    # datetime, and ids as Integer or String, so an unchanged assignment
    # never reads as a divergence.
    def state_key(h)
      return nil if h.nil?

      { p: h["personId"].to_i, pr: h["projectId"].to_i, r: h["roleId"].to_i,
        s: h["startDate"].to_s[0, 10], e: h["endDate"].to_s[0, 10], m: h["minutesPerDay"].to_i }
    end

    def conflict(current) = Result.new(status: :conflict, conflict: current, before: current)

    # The group half of adopt_into: takes the "fresh" (unowned) rows of a
    # split, validates them as one unit against the live human snapshot,
    # and either returns an all-conflict Hash (zero writes) or performs the
    # create-all-then-delete-once sequence. Returns Hash{source_key => Result}.
    def group_adopt(fresh, adopt_expected, preview)
      runn_person_id = resolver.runn_person_id_for(fresh.first.contributor)
      if runn_person_id.nil?
        raise UnresolvedContributor,
          "contributor #{fresh.first.contributor_id} has no unique active Runn person (email matched 0 or multiple)"
      end

      assignments = @runn.get_assignments
      live = assignments.find { |a| a["id"] == adopt_expected["id"] }

      if live.nil? ||                                          # target gone → human already changed it
         live["note"].to_s.include?("[stacksbot:") ||          # already owned — never re-adopt
         !same_state?(live, adopt_expected) ||                 # target moved since the snapshot
         fresh.any? { |r| r.runn_project_id.to_i != live["projectId"].to_i } || # never split a human across projects
         runn_person_id.to_i != live["personId"].to_i ||        # resolved person ≠ the human being replaced
         fresh.any? { |r| r.contributor_id != fresh.first.contributor_id } # mixed contributors in one adopt group
        return fresh.each_with_object({}) { |r, h| h[r.source_key] = conflict(live) }
      end

      role_id = live["roleId"]
      desired_by_key = fresh.each_with_object({}) do |r, h|
        h[r.source_key] = {
          "personId" => runn_person_id, "projectId" => r.runn_project_id, "roleId" => role_id,
          "startDate" => r.start_date.iso8601, "endDate" => r.end_date.iso8601,
          "minutesPerDay" => r.minutes_per_day,
        }
      end

      if preview
        return fresh.each_with_object({}) do |r, h|
          h[r.source_key] = Result.new(status: :preview, before: live, after: desired_by_key[r.source_key])
        end
      end

      created = [] # [{ row:, hash: }, ...] in create order, for compensating rollback
      begin
        fresh.each do |row|
          desired = desired_by_key[row.source_key]
          Mcp::WriteGuard.check!
          resp = @runn.create_assignment(
            person_id: desired["personId"], project_id: desired["projectId"], role_id: role_id,
            start_date: desired["startDate"], end_date: desired["endDate"],
            minutes_per_day: desired["minutesPerDay"], note: provenance_note(row.source_key, row.note)
          )
          hash = normalize_created(resp, desired, row.source_key, row.note)
          created << { row: row, hash: hash }
        end
      rescue StandardError => e
        created.each { |c| @runn.delete_assignment(c[:hash]["id"]) rescue nil }
        raise e
      end

      begin
        Mcp::WriteGuard.check!
        @runn.delete_assignment(live["id"])
      rescue StandardError => e
        # total rollback: every create succeeded but the one delete didn't —
        # undo all of them so the human assignment is the only survivor.
        created.each { |c| @runn.delete_assignment(c[:hash]["id"]) rescue nil }
        raise e
      end

      created.each_with_object({}) do |c, h|
        c[:row].update!(runn_assignment_id: c[:hash]["id"], last_synced_runn_state: c[:hash])
        h[c[:row].source_key] =
          Result.new(status: :applied, before: live, after: c[:hash], runn_assignment_id: c[:hash]["id"])
      end
    end
  end
end
