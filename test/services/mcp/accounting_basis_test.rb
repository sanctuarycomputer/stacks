require 'test_helper'

# garden3d reports on the ACCRUAL basis (Hugh, 2026-09-28: "ensure we ALWAYS use accrual basis").
# #179 flipped five tools' defaults one by one; this makes accrual structural: one module owns the
# default and the validation, and a registry test fails for any read tool that takes an
# accounting_method without going through it.
class Mcp::AccountingBasisTest < ActiveSupport::TestCase
  test 'resolve: omitted, nil or blank means accrual; cash only when asked for; anything else is an error' do
    assert_equal ['accrual', nil], Mcp::AccountingBasis.resolve(nil)
    assert_equal ['accrual', nil], Mcp::AccountingBasis.resolve('')
    assert_equal ['accrual', nil], Mcp::AccountingBasis.resolve(' accrual ')
    assert_equal ['cash', nil], Mcp::AccountingBasis.resolve('cash')
    method, err = Mcp::AccountingBasis.resolve('both')
    assert_nil method
    assert_equal "Invalid accounting_method 'both'. Valid: accrual, cash", err
  end

  test 'every read tool that takes accounting_method uses the shared schema and resolver (no per-tool defaults)' do
    finance = Mcp::Server::TOOLS.select { |t| t.input_schema_value.to_h.dig(:properties, :accounting_method) }
    assert_equal %w[explore_okr get_enterprise_health get_okr_grid get_quarterly_report get_studio_health],
                 finance.map(&:name_value).sort, 'a new finance tool must be added here deliberately'
    finance.each do |tool|
      assert_equal Mcp::AccountingBasis::SCHEMA, tool.input_schema_value.to_h.dig(:properties, :accounting_method),
                   "#{tool.name_value} must describe accounting_method with Mcp::AccountingBasis::SCHEMA"
      param = tool.method(:call).parameters.find { |_, name| name == :accounting_method }
      assert_equal :key, param&.first, "#{tool.name_value}: accounting_method must be an optional keyword"
      source = File.read(tool.method(:call).source_location.first)
      assert_includes source, 'AccountingBasis.resolve', "#{tool.name_value} must validate through Mcp::AccountingBasis.resolve"
      refute_match(/accounting_method:\s*'(cash|accrual)'/, source, "#{tool.name_value} must not hard-code its own default")
    end
  end
end
