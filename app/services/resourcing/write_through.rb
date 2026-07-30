module Resourcing
  # Applies a projected_assignment change through to Runn, guarded so a human's
  # Runn edit can never be clobbered:
  #   - CAS: apply only if live owned Runn still equals last_synced_runn_state
  #   - provenance: only mutate assignments we own (marker still present in note)
  #   - compensating rollback: undo created rows on a partial failure
  # Only `work` rows own Runn assignments; time_off/reduced are pure modifiers.
  class WriteThrough
    Result = Struct.new(:status, :before, :after, :runn_assignment_ids, :conflict, keyword_init: true)

    def self.provenance_marker(source_key)
      "[stacksbot:#{source_key}]"
    end

    def initialize(runn: Stacks::Runn.new(max_retries: 0))
      @runn = runn
    end
    attr_writer :runn

    def apply(row, preview: false)
      scope = scope_rows(row)
      work_rows = scope.select { |r| r.kind == "work" }
      modifier_rows = scope.reject { |r| r.kind == "work" }

      owned_ids = scope.flat_map(&:owned_runn_assignment_ids).uniq
      live_owned = fetch_owned(owned_ids)

      return conflict(live_owned) unless cas_ok?(scope, live_owned, owned_ids)

      leave = row.runn_person_id ? @runn.get_leave_for_person(row.runn_person_id) : []
      desired = SegmentPlan.new(work_rows: work_rows, modifier_rows: modifier_rows, native_leave: leave)
                           .desired_segments

      if segments_match?(desired, live_owned)
        return Result.new(status: :noop, before: live_owned, after: live_owned, runn_assignment_ids: owned_ids)
      end
      return Result.new(status: :preview, before: live_owned, after: desired.map { |s| segment_hash(s) }) if preview

      created = replace!(delete_ids: owned_ids, desired: desired)
      persist!(work_rows, created)
      Result.new(status: :applied, before: live_owned,
                 after: created.map { |c| c[:hash] }, runn_assignment_ids: created.map { |c| c[:id] })
    end

    # Deletes the Runn assignment(s) this row owns, CAS + provenance guarded.
    # Backs DELETE ?archive_runn=true. Does NOT re-plan sibling rows and does
    # NOT mutate the row — the caller destroys the row only if this returns
    # non-conflict.
    def archive(row)
      owned_ids = row.owned_runn_assignment_ids
      return Result.new(status: :noop, before: [], after: [], runn_assignment_ids: []) if owned_ids.empty?

      live_owned = fetch_owned(owned_ids)
      return conflict(live_owned) unless cas_ok?([row], live_owned, owned_ids)

      owned_ids.each { |id| @runn.delete_assignment(id) }
      Result.new(status: :applied, before: live_owned, after: [], runn_assignment_ids: [])
    end

    private

    # --- scope ---------------------------------------------------------------

    def scope_rows(row)
      rows = ProjectedAssignment.for_person(row.runn_person_id).includes(:project_tracker).to_a
      return rows if row.project_tracker_id.nil? # an org-wide write touches the whole person

      trackers = [row.project_tracker_id, nil]
      rows.select { |r| trackers.include?(r.project_tracker_id) }
    end

    # --- CAS + provenance ----------------------------------------------------

    def fetch_owned(owned_ids)
      return [] if owned_ids.empty?

      by_id = @runn.get_assignments.index_by { |a| a["id"] }
      owned_ids.map { |id| by_id[id] } # nil where a human deleted an owned assignment
    end

    def cas_ok?(scope, live_owned, owned_ids)
      # a claimed-owned assignment vanished, or lost our marker → a human took over
      return false if live_owned.any?(&:nil?)

      owned_ids.zip(live_owned).each do |id, a|
        row = scope.find { |r| r.owned_runn_assignment_ids.include?(id) }
        return false unless a["note"].to_s.include?(WriteThrough.provenance_marker(row.source_key))
      end
      baseline = scope.flat_map { |r| Array(r.last_synced_runn_state) }
      normalize(live_owned) == normalize(baseline)
    end

    # --- apply with rollback -------------------------------------------------

    def replace!(delete_ids:, desired:)
      created = []
      begin
        desired.each do |seg|
          resp = @runn.create_assignment(
            person_id: seg.runn_person_id, project_id: seg.runn_project_id, role_id: seg.runn_role_id,
            start_date: seg.start_date.iso8601, end_date: seg.end_date.iso8601,
            minutes_per_day: seg.minutes_per_day, note: provenance_note(seg),
          )
          assignment_ids(resp).each { |id| created << { id: id, source_key: seg.source_key, hash: live_hash(id, seg) } }
        end
        delete_ids.each { |id| @runn.delete_assignment(id) }
        created
      rescue StandardError => e
        created.each { |c| safe_delete(c[:id]) } # compensating rollback
        raise e
      end
    end

    def safe_delete(id)
      @runn.delete_assignment(id)
    rescue StandardError
      nil
    end

    # --- persistence ---------------------------------------------------------

    def persist!(work_rows, created)
      work_rows.each do |work|
        mine = created.select { |c| c[:source_key] == work.source_key }
        work.update!(runn_assignment_ids: mine.map { |c| c[:id] },
                     last_synced_runn_state: mine.map { |c| c[:hash] })
      end
    end

    # --- helpers -------------------------------------------------------------

    def segments_match?(desired, live_owned)
      normalize(desired.map { |s| segment_hash(s) }) == normalize(live_owned)
    end

    # compare only the fields that define an assignment (ignore id/note)
    def normalize(rows)
      rows.compact.map do |r|
        { person: r["personId"], project: r["projectId"], role: r["roleId"],
          start: r["startDate"], end: r["endDate"], minutes: r["minutesPerDay"] }
      end.sort_by(&:to_a)
    end

    def segment_hash(seg)
      { "personId" => seg.runn_person_id, "projectId" => seg.runn_project_id, "roleId" => seg.runn_role_id,
        "startDate" => seg.start_date.iso8601, "endDate" => seg.end_date.iso8601, "minutesPerDay" => seg.minutes_per_day }
    end

    def live_hash(id, seg)
      segment_hash(seg).merge("id" => id, "note" => provenance_note(seg))
    end

    def provenance_note(seg)
      marker = WriteThrough.provenance_marker(seg.source_key)
      seg.note.present? ? "#{seg.note} #{marker}" : marker
    end

    def assignment_ids(resp)
      rows = resp.is_a?(Hash) ? [resp] : Array(resp)
      rows.map { |a| a.is_a?(Hash) ? a["id"] : a }.compact
    end

    def conflict(live_owned)
      Result.new(status: :conflict, conflict: live_owned.compact, before: live_owned.compact)
    end
  end
end
