module Resourcing
  # Pure: turns a person's projected_assignment rows into the DESIRED set of Runn
  # work segments. No DB writes, no Runn calls. time_off carves; reduced scales.
  class SegmentPlan
    Segment = Struct.new(:runn_person_id, :runn_project_id, :runn_role_id,
                         :start_date, :end_date, :minutes_per_day, :note, :source_key,
                         keyword_init: true)

    def initialize(work_rows:, modifier_rows:)
      @work_rows = work_rows
      @modifier_rows = modifier_rows
    end

    def desired_segments
      @work_rows.flat_map { |work| segments_for(work) }
    end

    private

    def segments_for(work)
      pieces = [{ start: work.start_date, end: work.end_date, minutes: work.minutes_per_day }]
      applicable(work).each do |mod|
        pieces = pieces.flat_map { |piece| apply_modifier(piece, mod) }
      end
      pieces
        .select { |p| p[:end] >= p[:start] && p[:minutes].positive? }
        .map { |p| to_segment(work, p) }
    end

    def applicable(work)
      @modifier_rows.select do |m|
        m.project_tracker_id.nil? || m.project_tracker_id == work.project_tracker_id
      end
    end

    def apply_modifier(piece, mod)
      lo = [piece[:start], mod.start_date].max
      hi = [piece[:end], mod.end_date].min
      return [piece] if lo > hi # no overlap

      case mod.kind
      when "time_off"
        [before(piece, lo), after(piece, hi)].compact
      when "reduced"
        scaled = (piece[:minutes] * (mod.capacity_pct || 0) / 100.0).round
        [before(piece, lo), { start: lo, end: hi, minutes: scaled }, after(piece, hi)].compact
      else
        [piece]
      end
    end

    def before(piece, lo)
      return nil if lo - 1 < piece[:start]

      piece.merge(end: lo - 1)
    end

    def after(piece, hi)
      return nil if hi + 1 > piece[:end]

      piece.merge(start: hi + 1)
    end

    def to_segment(work, piece)
      Segment.new(
        runn_person_id: work.runn_person_id,
        runn_project_id: work.runn_project_id,
        runn_role_id: work.runn_role_id,
        start_date: piece[:start],
        end_date: piece[:end],
        minutes_per_day: piece[:minutes],
        note: work.note,
        source_key: work.source_key,
      )
    end
  end
end
