class Api::V1::ProjectedAssignmentsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  ATTRS = %i[contributor_id project_tracker_id start_date end_date
             minutes_per_day note managed_by].freeze

  def upsert
    adopt = params[:adopt_expected]&.permit!&.to_h  # the human snapshot, if this is an adopt
    result = apply_one(params.permit(:source_key, *ATTRS), adopt: adopt)
    render json: result, status: http_status(result[:status])
  rescue Mcp::WriteGuard::CapExceeded => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  rescue Resourcing::WriteThrough::UnresolvedContributor, Resourcing::WriteThrough::UnresolvableRole => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  def destroy
    row = ProjectedAssignment.find_by(source_key: params[:source_key])
    return render json: { status: "noop" }, status: :ok if row.nil?

    if ActiveModel::Type::Boolean.new.cast(params[:archive_runn])
      result = write_through.archive(row)
      if result.status == :conflict
        return render json: { status: "conflict", conflict: result.conflict }, status: :conflict
      end
    end
    row.destroy!
    render json: { status: "deleted" }, status: :ok
  rescue Mcp::WriteGuard::CapExceeded => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  def batch
    deferred = false
    results = Array(params[:items]).map do |item|
      permitted = item.permit(:source_key, *ATTRS)
      adopt = item[:adopt_expected]&.permit!&.to_h  # the human snapshot, if this item is an adopt
      next { status: "deferred", source_key: permitted[:source_key] } if deferred

      begin
        apply_one(permitted, adopt: adopt)
      rescue Mcp::WriteGuard::CapExceeded
        deferred = true
        { status: "deferred", source_key: permitted[:source_key] }
      rescue Resourcing::WriteThrough::UnresolvedContributor, Resourcing::WriteThrough::UnresolvableRole => e
        { status: "error", source_key: permitted[:source_key], error: e.message }
      end
    end
    render json: { results: results }, status: :ok
  end

  # Atomic N-way split: replaces ONE human-authored Runn assignment with N
  # stacksbot-owned rows via WriteThrough#adopt_into (see that method for the
  # rollback ordering). Segments are upserted by source_key like upsert/batch,
  # but validated as a whole BEFORE anything is saved or written to Runn —
  # any invalid segment aborts the entire request with no side effects.
  def adopt
    adopt_expected = params[:adopt_expected]&.permit!&.to_h
    segments = Array(params[:segments])
    if adopt_expected.blank? || segments.blank?
      return render json: { status: "error", error: "adopt requires adopt_expected and at least one segment" },
        status: :unprocessable_entity
    end

    rows = segments.map do |seg|
      permitted = seg.permit(:source_key, *ATTRS)
      r = ProjectedAssignment.find_or_initialize_by(source_key: permitted[:source_key])
      # never let an upsert overwrite a permanently-yielded row (WriteThrough#apply
      # then no-ops it via the owned partition); leaving managed_by intact is the guard.
      r.assign_attributes(permitted.except(:source_key).to_h.symbolize_keys) unless r.managed_by == "relinquished"
      r
    end
    invalid = rows.reject(&:valid?)
    if invalid.any?
      return render json: { results: invalid.map { |r| { status: "invalid", source_key: r.source_key, errors: r.errors.full_messages } } },
        status: :unprocessable_entity
    end

    rows.each(&:save!)
    results = write_through.adopt_into(rows: rows, adopt_expected: adopt_expected, preview: preview?)
    render json: { results: rows.zip(results).map { |r, res|
      { status: res.status.to_s, source_key: r.source_key, before: res.before,
        after: res.after, runn_assignment_id: res.runn_assignment_id, conflict: res.conflict }.compact
    } }, status: :ok
  rescue Mcp::WriteGuard::CapExceeded => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  rescue Resourcing::WriteThrough::UnresolvedContributor, Resourcing::WriteThrough::UnresolvableRole => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  private

  # Applies a single upsert. Returns a Hash whose :status is a String
  # ("applied"|"noop"|"conflict"|"preview"|"invalid"). Raises WriteGuard::CapExceeded,
  # UnresolvedContributor, UnresolvableRole.
  def apply_one(attrs, adopt: nil)
    source_key = attrs[:source_key]
    row = ProjectedAssignment.find_or_initialize_by(source_key: source_key)
    # a human took this assignment back — the row is permanently yielded. Return
    # before assign_attributes so an incoming upsert can't overwrite managed_by
    # and resurrect management (the guard in WriteThrough#apply reads the row,
    # but the controller must not clobber the stored value first).
    return { status: "noop", source_key: source_key } if row.managed_by == "relinquished"
    row.assign_attributes(attrs.except(:source_key).to_h.symbolize_keys)
    unless row.valid?
      return { status: "invalid", source_key: source_key, errors: row.errors.full_messages }
    end

    row.save!
    result = write_through.apply(row, preview: preview?, adopt_expected: adopt)
    { status: result.status.to_s, source_key: source_key, before: result.before,
      after: result.after, runn_assignment_id: result.runn_assignment_id, conflict: result.conflict }.compact
  end

  def preview?
    ActiveModel::Type::Boolean.new.cast(params[:preview])
  end

  # One WriteThrough for the whole request so a batch fetches the Runn people
  # list once (memoized on its resolver) instead of once per item.
  def write_through
    @write_through ||= Resourcing::WriteThrough.new
  end

  def http_status(status)
    case status
    when "invalid" then :unprocessable_entity
    when "conflict" then :conflict
    else :ok
    end
  end
end
