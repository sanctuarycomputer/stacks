require 'test_helper'

class Mcp::DateRangeTest < ActiveSupport::TestCase
  test 'both bounds build an inclusive range' do
    r = Mcp::DateRange.parse('2026-01-01', '2026-02-01')
    assert r.cover?(Time.zone.parse('2026-01-15'))
    refute r.cover?(Time.zone.parse('2026-03-01'))
  end

  test 'a single bound builds an open-ended range' do
    assert Mcp::DateRange.parse('2026-01-01', nil).cover?(Time.zone.parse('2030-01-01'))  # endless
    refute Mcp::DateRange.parse('2026-01-01', nil).cover?(Time.zone.parse('2020-01-01'))
    assert Mcp::DateRange.parse(nil, '2026-01-01').cover?(Time.zone.parse('2000-01-01'))  # beginless
  end

  test 'no bounds or unparseable input yields nil (filter is skipped)' do
    assert_nil Mcp::DateRange.parse(nil, nil)
    assert_nil Mcp::DateRange.parse('', '')
    assert_nil Mcp::DateRange.parse('not-a-date', nil)
  end
end
