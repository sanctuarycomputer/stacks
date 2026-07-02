module Mcp
  # Shared read-only scoping for the AR tools. CRITICAL: QboInvoice#data
  # lazily re-fetches from the QBO API when the stored jsonb is empty, so
  # every query here must exclude unsynced rows in SQL — a tool call must
  # never trigger a live network request.
  module QboReceivables
    SYNCED_ROWS_SQL =
      "qbo_invoices.data IS NOT NULL AND qbo_invoices.data <> '{}'::jsonb " \
      "AND qbo_invoices.data->>'due_date' IS NOT NULL".freeze

    def self.resolve_enterprises(name)
      scope = Enterprise.joins(:qbo_account).distinct
      return [scope.to_a, nil] if name.blank?
      matches = scope.where('LOWER(enterprises.name) = ?', name.to_s.downcase).to_a
      return [matches, nil] if matches.any?
      valid = scope.pluck(:name).sort
      [nil, "Unknown enterprise '#{name}'. Valid enterprises: #{valid.join(', ')}"]
    end

    def self.receivables(enterprise)
      QboInvoice
        .joins(:qbo_account)
        .where(qbo_accounts: { enterprise_id: enterprise.id })
        .where(SYNCED_ROWS_SQL)
        .select { |inv| inv.email_status == 'EmailSent' && inv.balance.positive? }
    end

    def self.days_overdue(invoice, as_of = Date.today)
      (as_of - invoice.due_date).to_i
    end

    def self.bucket_key(days_overdue)
      return 'current' if days_overdue <= 0
      return 'days_0_30' if days_overdue <= 30
      return 'days_31_60' if days_overdue <= 60
      return 'days_61_90' if days_overdue <= 90
      'days_90_plus'
    end

    def self.error_response(message)
      MCP::Tool::Response.new([{ type: 'text', text: { error: message }.to_json }])
    end
  end
end
