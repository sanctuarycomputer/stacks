module Qbo
  # Resolves which QBO chart account a Stacks-managed bill line posts to.
  #
  #   Qbo::BillAccountResolver.new(enterprise)
  #     .account_for("payout_commission", contributor: c, project_tracker: pt)
  #   # => QboChartAccount
  #
  # Precedence (first mapping wins):
  #   1. project-tracker-level (when a tracker is given)
  #   2. contributor-level
  #   3. entity-level default
  #
  # Raises Qbo::UnmappedLineItemError when no mapping matches or the mapped
  # chart account is missing/inactive in the local mirror. No silent
  # fallback — replaces the legacy hard-coded find_qbo_account! routing.
  class BillAccountResolver
    def initialize(enterprise)
      @enterprise = enterprise
    end

    def account_for(line_item_key, contributor:, project_tracker: nil)
      key = line_item_key.to_s
      unless QboBillAccountMapping::LINE_ITEM_KEYS.include?(key)
        raise ArgumentError, "Unknown line_item_key #{key.inspect} (valid: #{QboBillAccountMapping::LINE_ITEM_KEYS.join(', ')})"
      end

      qa = @enterprise&.qbo_account
      if qa.nil?
        raise UnmappedLineItemError, "Enterprise #{@enterprise&.name.inspect} has no connected QboAccount"
      end

      tried = []
      mapping = nil

      if project_tracker.present?
        tried << "ProjectTracker##{project_tracker.id}"
        mapping = scope(key).find_by(project_tracker_id: project_tracker.id)
      end
      if mapping.nil? && contributor.present?
        tried << "Contributor##{contributor.id}"
        mapping = scope(key).find_by(contributor_id: contributor.id, project_tracker_id: nil)
      end
      if mapping.nil?
        tried << "entity default"
        mapping = scope(key).find_by(project_tracker_id: nil, contributor_id: nil)
      end

      if mapping.nil?
        raise UnmappedLineItemError,
          "Enterprise #{@enterprise.name.inspect} has no QBO account mapping for #{key} " \
          "(tried #{tried.join(', ')})"
      end

      chart_account = QboChartAccount.find_by(qbo_account_id: qa.id, qbo_id: mapping.qbo_chart_account_qbo_id)
      if chart_account.nil? || !chart_account.active?
        state = chart_account.nil? ? "missing from" : "inactive in"
        raise UnmappedLineItemError,
          "Enterprise #{@enterprise.name.inspect}: mapping for #{key} (#{mapping.subject_label}) points at " \
          "QBO chart account #{mapping.qbo_chart_account_qbo_id.inspect} which is #{state} the local mirror"
      end

      chart_account
    end

    private

    def scope(key)
      QboBillAccountMapping.where(enterprise_id: @enterprise.id, line_item_key: key)
    end
  end
end
