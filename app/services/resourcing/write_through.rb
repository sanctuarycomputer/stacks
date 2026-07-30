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

    def apply(row, preview: false)
      runn_person_id = RunnPersonResolver.new(@runn).runn_person_id_for(row.contributor)
      if runn_person_id.nil?
        raise UnresolvedContributor,
          "contributor #{row.contributor_id} has no unique active Runn person (email matched 0 or multiple)"
      end

      assignments = @runn.get_assignments
      current = row.runn_assignment_id && assignments.find { |a| a["id"] == row.runn_assignment_id }

      # CAS + provenance: if we think we own an assignment, it must still be ours & unchanged.
      if row.runn_assignment_id
        return conflict(current) if current.nil? # human deleted it
        return conflict(current) unless current["note"].to_s.include?(self.class.provenance_marker(row.source_key))
        return conflict(current) unless same_state?(current, row.last_synced_runn_state)
      end

      role_id = current ? current["roleId"] : most_recent_role_id(runn_person_id, assignments)
      raise UnresolvableRole, "no Runn role for contributor #{row.contributor_id}" if role_id.nil?

      desired = {
        "personId" => runn_person_id, "projectId" => row.runn_project_id, "roleId" => role_id,
        "startDate" => row.start_date.iso8601, "endDate" => row.end_date.iso8601,
        "minutesPerDay" => row.minutes_per_day,
      }
      if current && same_desired?(current, desired)
        return Result.new(status: :noop, before: current, after: current, runn_assignment_id: row.runn_assignment_id)
      end
      return Result.new(status: :preview, before: current, after: desired) if preview

      new_hash = replace!(old_id: row.runn_assignment_id, desired: desired, source_key: row.source_key)
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

    # create the (shorter/new) assignment first, then delete the old — rollback the create on failure.
    def replace!(old_id:, desired:, source_key:)
      Mcp::WriteGuard.check!
      created = @runn.create_assignment(
        person_id: desired["personId"], project_id: desired["projectId"], role_id: desired["roleId"],
        start_date: desired["startDate"], end_date: desired["endDate"],
        minutes_per_day: desired["minutesPerDay"], note: provenance_note(desired, source_key)
      )
      new_hash = normalize_created(created, desired, source_key)
      begin
        if old_id
          Mcp::WriteGuard.check!
          @runn.delete_assignment(old_id)
        end
      rescue StandardError => e
        @runn.delete_assignment(new_hash["id"]) rescue nil # compensating rollback
        raise e
      end
      new_hash
    end

    # Runn create returns a bare Hash OR an array of segments; we expect exactly one here
    # (no native leave → no auto-split). Take the first, stamp the fields we sent.
    def normalize_created(resp, desired, source_key)
      row = resp.is_a?(Array) ? resp.first : resp
      id = row.is_a?(Hash) ? row["id"] : row
      desired.merge("id" => id, "note" => provenance_note(desired, source_key))
    end

    def provenance_note(desired, source_key)
      self.class.provenance_marker(source_key)
    end

    # most-recent (by endDate) role for this person across the given live assignments; nil if none
    def most_recent_role_id(runn_person_id, assignments)
      assignments.select { |a| a["personId"] == runn_person_id }
                 .max_by { |a| a["endDate"].to_s }&.dig("roleId")
    end

    # CAS baseline compare (ignore id/note): person/project/role/dates/minutes
    def same_state?(a, b) = state_key(a) == state_key(b)
    def same_desired?(a, desired) = state_key(a) == state_key(desired)

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
