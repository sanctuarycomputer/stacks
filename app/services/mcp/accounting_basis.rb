module Mcp
  # The ONE place a finance read tool gets its accounting basis. garden3d reports on the ACCRUAL basis
  # (Hugh, 2026-09-28: "ensure we ALWAYS use accrual basis"); cash-basis profitability produced 28 wrong
  # observations on 2026-09-10. #179 flipped five per-tool defaults by hand; routing every tool through
  # this module (enforced by test/services/mcp/accounting_basis_test.rb) means a new finance tool can't
  # quietly default to cash again. Cash stays available, but only when a caller explicitly asks for it.
  module AccountingBasis
    DEFAULT = 'accrual'.freeze
    VALID = %w[accrual cash].freeze
    SCHEMA = {
      type: 'string',
      description: 'accrual (the default: garden3d reports on the accrual basis) or cash (only when cash figures are explicitly wanted)',
    }.freeze

    # nil, blank or omitted → accrual (an MCP client may send null for "not set").
    # Returns [method, nil] or [nil, error_message].
    def self.resolve(value)
      method = value.to_s.strip
      method = DEFAULT if method.empty?
      return [method, nil] if VALID.include?(method)

      [nil, "Invalid accounting_method '#{method}'. Valid: #{VALID.join(', ')}"]
    end
  end
end
