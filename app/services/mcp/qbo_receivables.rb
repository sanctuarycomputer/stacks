module Mcp
  # Shared read-only scoping for the AR tools. CRITICAL: QboInvoice#data
  # lazily re-fetches from the QBO API when the stored jsonb is empty, so
  # every query here must exclude unsynced rows in SQL — a tool call must
  # never trigger a live network request. Rows are parsed once into plain
  # Receivable structs; malformed rows are dropped here, so consumers never
  # need their own rescue-and-skip.
  module QboReceivables
    # Open, sent receivables only — filtered in SQL so years of paid/unsent
    # history never leave Postgres. The balance cast is wrapped in a CASE
    # (Postgres does not guarantee AND short-circuit order) so a non-numeric
    # balance is excluded rather than raising.
    #
    # NOTE: uses a single-quoted heredoc terminator (<<~'SQL') so the \d and
    # \. escapes below reach Postgres literally. A plain <<~SQL heredoc
    # follows Ruby double-quoted-string escape rules, which silently strip
    # the backslash from unrecognized escapes like \d (i.e. "\d" becomes
    # "d"), corrupting the regex.
    RECEIVABLE_ROWS_SQL = <<~'SQL'.squish.freeze
      qbo_invoices.data IS NOT NULL
      AND qbo_invoices.data <> '{}'::jsonb
      AND qbo_invoices.data->>'due_date' IS NOT NULL
      AND qbo_invoices.data->>'email_status' = 'EmailSent'
      AND CASE WHEN qbo_invoices.data->>'balance' ~ '^-?\d+(\.\d+)?$'
               THEN (qbo_invoices.data->>'balance')::numeric > 0
               ELSE FALSE END
    SQL

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
    def self.receivables(enterprises, as_of: Date.today)
      QboInvoice
        .joins(:qbo_account)
        .where(qbo_accounts: { enterprise_id: enterprises.map(&:id) })
        .where(RECEIVABLE_ROWS_SQL)
        .select('qbo_invoices.*, qbo_accounts.enterprise_id AS enterprise_id')
        .filter_map { |inv| build_receivable(inv, as_of) }
    end

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

    def self.build_receivable(inv, as_of)
      due_date = inv.due_date
      balance = inv.balance
      total = inv.total
      days_overdue = (as_of - due_date).to_i
      partially_paid = balance != total
      status =
        if days_overdue.positive?
          partially_paid ? :partially_paid_overdue : :unpaid_overdue
        else
          partially_paid ? :partially_paid : :unpaid
        end
      Receivable.new(
        enterprise_id: inv[:enterprise_id],
        doc_number: inv.data['doc_number'],
        customer: begin inv.customer_ref['name'].presence || 'Unknown' rescue 'Unknown' end,
        total: total,
        balance: balance,
        due_date: due_date,
        days_overdue: days_overdue,
        status: status,
        qbo_invoice_link: inv.qbo_invoice_link,
        display_name: inv.display_name
      )
    rescue StandardError
      nil # malformed synced row — drop it here, the single enforcement point
    end
    private_class_method :build_receivable
  end
end
