module Mcp
  # Shared read-only scoping for the AR tools. CRITICAL: QboInvoice#data
  # lazily re-fetches from the QBO API when the stored jsonb is empty, so
  # every query here must exclude unsynced rows in SQL — a tool call must
  # never trigger a live network request. Rows are parsed once into plain
  # Receivable structs; malformed rows are dropped here, so consumers never
  # need their own rescue-and-skip.
  module QboReceivables
    Receivable = Struct.new(
      :invoice_id, :enterprise_id, :doc_number, :customer_id, :customer, :total, :balance,
      :due_date, :days_overdue, :status, :qbo_invoice_link, :display_name,
      keyword_init: true
    )

    def self.resolve_enterprises(name)
      scope = Enterprise.joins(:qbo_account).distinct.order(:name)
      name = name.to_s.strip # LLM callers pad names with whitespace
      return [scope.to_a, nil] if name.blank?
      # Match in Ruby (Unicode-aware casecmp?), not SQL LOWER(), so non-ASCII
      # names resolve regardless of the database collation. Tiny table.
      matches = scope.to_a.select { |e| e.name.casecmp?(name) }
      return [matches, nil] if matches.any?
      [nil, "Unknown enterprise '#{name}'. Valid enterprises: #{scope.pluck(:name).join(', ')}"]
    end

    # One query for all enterprises; one parse per row; malformed rows dropped
    # (with a warn — a silent mass-drop must not read as "nothing outstanding").
    # min_days_overdue filters BEFORE detail fields are computed so discarded
    # rows never pay for currency formatting.
    def self.receivables(enterprises, as_of: Date.today, details: false, min_days_overdue: nil)
      # The scope's balance regex (and its due_date/balance NULL checks)
      # silently exclude rows via SQL three-valued logic: NOT (NULL ~ regex)
      # is NULL, not true, so a sent row missing due_date or balance (or with
      # a non-numeric balance, e.g. "1,200.00") never reaches build_receivable
      # to warn there. This SQL-side check catches all of those — a cheap
      # count-only query so a silent mass-drop can't read as "nothing
      # outstanding".
      malformed = QboInvoice
        .malformed_sent_receivables
        .joins(:qbo_account)
        .where(qbo_accounts: { enterprise_id: enterprises.map(&:id) })
        .pluck(:id, :qbo_id)
      if malformed.any?
        Rails.logger.warn("[Mcp::QboReceivables] #{malformed.size} invoice(s) excluded as malformed (missing due_date/balance or non-numeric balance): #{malformed.map { |id, qbo_id| "id=#{id} qbo_id=#{qbo_id}" }.join(', ')}")
      end

      QboInvoice
        .open_receivables
        .joins(:qbo_account)
        .where(qbo_accounts: { enterprise_id: enterprises.map(&:id) })
        .select('qbo_invoices.*, qbo_accounts.enterprise_id AS enterprise_id')
        .filter_map { |inv| build_receivable(inv, as_of, details: details, min_days_overdue: min_days_overdue) }
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

    def self.build_receivable(inv, as_of, details:, min_days_overdue:)
      due_date = inv.due_date
      balance = Float(inv.data['balance'])
      days_overdue = (as_of - due_date).to_i
      return nil if min_days_overdue && days_overdue < min_days_overdue
      total = details ? (Float(inv.data['total']) rescue nil) : nil # total is display-only; a receivable with unknown total still owes its balance
      ref = inv.customer_ref
      Receivable.new(
        invoice_id: inv.id,
        enterprise_id: inv[:enterprise_id],
        doc_number: inv.data['doc_number'],
        customer_id: ref['value'],
        customer: ref['name'].presence,
        total: total,
        balance: balance,
        due_date: due_date,
        days_overdue: days_overdue,
        # Detail fields only for consumers that emit them (the list tool).
        # status stays delegated to the model (single source of truth);
        # display_name recomputing it internally is the accepted cost of that.
        status: details ? inv.status : nil,
        qbo_invoice_link: details ? inv.qbo_invoice_link : nil,
        display_name: details ? inv.display_name : nil
      )
    rescue StandardError => e
      Rails.logger.warn("[Mcp::QboReceivables] skipping malformed invoice id=#{inv.id} qbo_id=#{inv.qbo_id}: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :build_receivable
  end
end
