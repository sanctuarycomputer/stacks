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
    class AdoptTargetMissing < StandardError; end

    def self.provenance_marker(source_key) = "[stacksbot:#{source_key}]"

    def initialize(runn: Stacks::Runn.new(max_retries: 0))
      @runn = runn
    end

    def apply(row, preview: false, adopt_expected: nil)
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
        return conflict(current) if current.nil? # human deleted it
        return conflict(current) unless current["note"].to_s.include?(self.class.provenance_marker(row.source_key))
        return conflict(current) unless same_state?(current, row.last_synced_runn_state)
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

    # DELETE ?archive_runn=true — remove the owned Runn assignment, CAS-guarded.
    # Does NOT mutate/destroy the row — the caller destroys it only on non-conflict.
    def archive(row)
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
  end
end
