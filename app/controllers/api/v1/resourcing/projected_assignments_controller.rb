class Api::V1::Resourcing::ProjectedAssignmentsController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  ATTRS = %i[project_tracker_id runn_person_id runn_role_id start_date end_date
             minutes_per_day kind capacity_pct is_placeholder note source_ref managed_by].freeze

  def upsert
    result = apply_one(params.permit(:source_key, *ATTRS))
    render json: result, status: http_status(result[:status])
  rescue ArgumentError, Mcp::WriteGuard::CapExceeded => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  def destroy
    row = ProjectedAssignment.find_by(source_key: params[:source_key])
    return render json: { status: "noop" }, status: :ok if row.nil?

    if ActiveModel::Type::Boolean.new.cast(params[:archive_runn])
      Mcp::WriteGuard.check!
      # empty the row's work so WriteThrough deletes its owned Runn assignments, CAS-guarded
      row.update!(kind: "time_off", minutes_per_day: 0) if row.kind == "work"
      result = Resourcing::WriteThrough.new.apply(row)
      return render json: { status: "conflict", conflict: result.conflict }, status: :conflict if result.status == :conflict
    end
    row.destroy!
    render json: { status: "deleted" }, status: :ok
  rescue Mcp::WriteGuard::CapExceeded => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
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

    Mcp::WriteGuard.check! unless preview?
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
