module InvoicePayouts
  # The most an invoice may pay out to contributors, net of commissions.
  #
  # One calculation shared by the pre-flight (MarginCheck) and the save-time
  # validation on ContributorPayout, so the two cannot disagree. Each line
  # mapped to a ProjectTracker is capped by that tracker's billing model;
  # anything else on the invoice uses the default model. A tracker-level
  # target_margin_override replaces all of that with one share.
  #
  # commissions_by_line: QBO line id (String, or nil when unknown) => dollars
  # of commission actually paid out against that line.
  class Cap
    Line = Struct.new(:id, :amount, :project_tracker, :rules, keyword_init: true)

    def initialize(invoice_tracker, commissions_by_line: {})
      @invoice_tracker = invoice_tracker
      @commissions_by_line = commissions_by_line.each_with_object(Hash.new(0.0)) do |(id, amount), h|
        h[id&.to_s] += amount.to_f
      end
    end

    def total
      @invoice_tracker.total.to_f
    end

    def total_commissions
      @commissions_by_line.values.sum.to_f
    end

    def post_commission_total
      (total - total_commissions).round(2)
    end

    def internal?
      @invoice_tracker.forecast_client.is_internal?
    end

    def override
      @invoice_tracker.margin_override
    end

    def default_rules
      Stacks::BillingModel.for(Stacks::BillingModel::DEFAULT)
    end

    def mapped_lines
      @mapped_lines ||= begin
        blueprint_lines = ((@invoice_tracker.blueprint || {})["lines"] || {}).values
        (@invoice_tracker.qbo_invoice&.line_items || []).filter_map do |line_item|
          metadata = blueprint_lines.find { |l| l["id"] == line_item["id"] }
          next unless metadata.present?
          ptfps = ProjectTrackerForecastProject.includes(:project_tracker).where(forecast_project_id: metadata["forecast_project"])
          next unless ptfps.length == 1
          pt = ptfps.first.project_tracker
          Line.new(id: line_item["id"].to_s, amount: line_item["amount"].to_f, project_tracker: pt, rules: pt.billing_rules)
        end
      end
    end

    def commission_for(line_id)
      @commissions_by_line.fetch(line_id.to_s, 0.0)
    end

    def treasury_share_for(line_id)
      return 0 if internal?
      return override if override
      line = mapped_lines.find { |l| l.id == line_id.to_s }
      (line&.rules || default_rules).treasury_share
    end

    def cap
      return post_commission_total if internal?
      return (post_commission_total * (1 - override)).to_f.round(2) if override

      mapped = mapped_lines
      attributed = mapped.sum { |l| commission_for(l.id) }
      mapped_part = mapped.sum { |l| (l.amount - commission_for(l.id)) * (1 - l.rules.treasury_share) }
      remainder = total - mapped.sum(&:amount) - (total_commissions - attributed)
      (mapped_part + remainder * (1 - default_rules.treasury_share)).to_f.round(2)
    end
  end
end
