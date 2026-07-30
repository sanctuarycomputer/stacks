class Api::V1::Resourcing::ProjectedAssignmentsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  ATTRS = %i[project_tracker_id contributor_id runn_role_id start_date end_date
             minutes_per_day kind capacity_pct is_placeholder note source_ref managed_by].freeze

  def upsert
    result = apply_one(params.permit(:source_key, *ATTRS))
    render json: result, status: http_status(result[:status])
  rescue Mcp::WriteGuard::CapExceeded => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  rescue Resourcing::WriteThrough::UnresolvedContributor => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  def destroy
    # NOTE: deleting a time_off/reduced modifier row removes only that row — it
    # does NOT restore the work assignment it carved/scaled (modifiers own
    # nothing). To un-split a work row, re-PUT it after removing the modifier.
    row = ProjectedAssignment.find_by(source_key: params[:source_key])
    return render json: { status: "noop" }, status: :ok if row.nil?

    if ActiveModel::Type::Boolean.new.cast(params[:archive_runn]) && row.owned_runn_assignment_ids.any?
      result = Resourcing::WriteThrough.new.archive(row)
      if result.status == :conflict
        return render json: { status: "conflict", conflict: result.conflict }, status: :conflict
      end
    end
    row.destroy!
    render json: { status: "deleted" }, status: :ok
  rescue Mcp::WriteGuard::CapExceeded => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  rescue Resourcing::WriteThrough::UnresolvedContributor => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  def batch
    deferred = false
    results = Array(params[:items]).map do |item|
      permitted = item.permit(:source_key, *ATTRS)
      next { status: "deferred", source_key: permitted[:source_key] } if deferred

      begin
        apply_one(permitted)
      rescue Mcp::WriteGuard::CapExceeded
        deferred = true
        { status: "deferred", source_key: permitted[:source_key] }
      rescue Resourcing::WriteThrough::UnresolvedContributor => e
        { status: "error", source_key: permitted[:source_key], error: e.message }
      end
    end
    render json: { results: results }, status: :ok
  end

  private

  # Applies a single upsert. Returns a Hash whose :status is a String
  # ("applied"|"noop"|"conflict"|"preview"|"invalid"). Raises WriteGuard::CapExceeded.
  def apply_one(attrs)
    source_key = attrs[:source_key]
    row = ProjectedAssignment.find_or_initialize_by(source_key: source_key)
    row.assign_attributes(attrs.except(:source_key).to_h.symbolize_keys)
    unless row.valid?
      return { status: "invalid", source_key: source_key, errors: row.errors.full_messages }
    end

    row.save!
    result = Resourcing::WriteThrough.new.apply(row, preview: preview?)
    { status: result.status.to_s, source_key: source_key, before: result.before,
      after: result.after, runn_assignment_ids: result.runn_assignment_ids, conflict: result.conflict }.compact
  end

  def preview?
    ActiveModel::Type::Boolean.new.cast(params[:preview])
  end

  def http_status(status)
    case status
    when "invalid" then :unprocessable_entity
    when "conflict" then :conflict
    else :ok
    end
  end
end
