module Mcp
  # Shared read-only scoping for the AR tools. CRITICAL: QboInvoice#data
  # lazily re-fetches from the QBO API when the stored jsonb is empty, so
  # every query here must exclude unsynced rows in SQL — a tool call must
  # never trigger a live network request. Rows are parsed once into plain
  # Receivable structs; malformed rows are dropped here, so consumers never
  # need their own rescue-and-skip.
  module QboReceivables
    Receivable = Struct.new(
      :enterprise_id, :doc_number, :customer, :total, :balance,
      :due_date, :days_overdue, :status, :qbo_invoice_link, :display_name,
      keyword_init: true
    )

    def self.resolve_enterprises(name)
      scope = Enterprise.joins(:qbo_account).distinct.order(:name)
      return [scope.to_a, nil] if name.blank?
      # Match in Ruby (Unicode-aware casecmp?), not SQL LOWER(), so non-ASCII
      # names resolve regardless of the database collation. Tiny table.
      matches = scope.to_a.select { |e| e.name.casecmp?(name.to_s) }
      return [matches, nil] if matches.any?
      [nil, "Unknown enterprise '#{name}'. Valid enterprises: #{scope.pluck(:name).join(', ')}"]
    end

    # One query for all enterprises; one parse per row; malformed rows dropped.
    def self.receivables(enterprises, as_of: Date.today, details: false)
      QboInvoice.open_receivables
        .joins(:qbo_account)
        .where(qbo_accounts: { enterprise_id: enterprises.map(&:id) })
        .select('qbo_invoices.*, qbo_accounts.enterprise_id AS enterprise_id')
        .filter_map { |inv| build_receivable(inv, as_of, details) }
    end

    BUCKETS = %w[current days_1_30 days_31_60 days_61_90 days_over_90].freeze

    # bucket_key must only ever return a member of BUCKETS.
    def self.bucket_key(days_overdue)
      return 'current' if days_overdue <= 0
      return 'days_1_30' if days_overdue <= 30
      return 'days_31_60' if days_overdue <= 60
      return 'days_61_90' if days_overdue <= 90
      'days_over_90'
    end

    def self.error_response(message)
      MCP::Tool::Response.new([{ type: 'text', text: { error: message }.to_json }])
    end

    def self.build_receivable(inv, as_of, details)
      due_date = inv.due_date
      balance = Float(inv.data['balance'])
      total = Float(inv.data['total'])
      days_overdue = (as_of - due_date).to_i
      Receivable.new(
        enterprise_id: inv[:enterprise_id],
        doc_number: inv.data['doc_number'],
        customer: begin inv.customer_ref['name'].presence || 'Unknown' rescue 'Unknown' end,
        total: total,
        balance: balance,
        due_date: due_date,
        days_overdue: days_overdue,
        status: inv.status,
        qbo_invoice_link: details ? inv.qbo_invoice_link : nil,
        display_name: details ? inv.display_name : nil
      )
    rescue StandardError
      nil # malformed synced row — drop it here, the single enforcement point
    end
    private_class_method :build_receivable
  end
end
