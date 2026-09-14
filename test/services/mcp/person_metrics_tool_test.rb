require 'test_helper'

class Mcp::PersonMetricsToolTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    travel_to Time.zone.parse('2026-07-15 12:00:00')
  end

  def admin!(email: 'ada@sanctuary.computer')
    AdminUser.create!(email: email, password: 'password123', password_confirmation: 'password123')
  end

  # key_metrics_for_period reads Studio.garden3d's snapshot for the gradation;
  # each entry is keyed by period label and carries the per-email utilization map.
  def g3d_with_snapshot!(entries, gradation: 'month')
    _tb, g3d = make_studio!
    g3d.update!(snapshot: { gradation => entries })
    g3d
  end

  def june_entry(email, billable: { '175.0' => 60.0, '150.0' => 20.0 }, sellable: 100.0,
                 non_billable: 12.0, non_sellable: 20.0, time_off: 8.0)
    {
      'label' => 'June, 2026',
      'utilization' => {
        email => {
          'billable' => billable,
          'sellable' => sellable,
          'non_billable' => non_billable,
          'non_sellable' => non_sellable,
          'time_off' => time_off,
        },
      },
    }
  end

  test 'returns per-period metrics with derived utilization_rate and sellable_ratio' do
    admin = admin!
    g3d_with_snapshot!([june_entry(admin.email)])
    AdminUser.any_instance.stubs(:skill_tree_points_on_date).returns(42)

    payload = mcp_payload(Mcp::GetPersonMetricsTool.call(email: admin.email, periods: 2, server_context: {}))

    assert_equal admin.email, payload['person']
    assert_equal 'month', payload['gradation']
    assert_equal 2, payload['periods'].length

    june = payload['periods'].last
    assert_equal 'June, 2026', june['label']
    assert_equal '2026-06-01', june['period_starts_at']
    assert_equal '2026-06-30', june['period_ends_at']
    assert_equal 42, june['skill_points']
    assert_equal 80.0, june['billable'], 'billable sums the by-rate hash'
    assert_equal 100.0, june['sellable']
    assert_equal 12.0, june['non_billable']
    assert_equal 20.0, june['non_sellable']
    assert_equal 8.0, june['time_off']
    assert_equal 80.0, june['utilization_rate'], 'billable / sellable * 100'
    assert_equal 83.33, june['sellable_ratio'], 'sellable / (sellable + non_sellable) * 100'
  end

  test 'a period with no utilization data for the person yields nil hours and 0 rates (no blowup)' do
    admin = admin!
    # May has no utilization entry for this email; June has sellable 0 (division guard).
    g3d_with_snapshot!([
      { 'label' => 'May, 2026', 'utilization' => {} },
      june_entry(admin.email, sellable: 0.0, non_sellable: 0.0),
    ])
    AdminUser.any_instance.stubs(:skill_tree_points_on_date).returns(10)

    payload = mcp_payload(Mcp::GetPersonMetricsTool.call(email: admin.email, periods: 2, server_context: {}))

    may, june = payload['periods']
    assert_equal 'May, 2026', may['label']
    assert_nil may['billable']
    assert_nil may['sellable']
    assert_equal 0.0, may['utilization_rate'], 'missing data mirrors the admin page rescue -> 0'
    assert_equal 0.0, may['sellable_ratio']
    assert_equal 10, may['skill_points'], 'skill points come from reviews, not the utilization map'

    assert_equal 0.0, june['sellable']
    assert_equal 0.0, june['utilization_rate'], 'zero sellable must not produce Infinity'
    assert_equal 0.0, june['sellable_ratio']
  end

  test 'unknown email errors without listing any other emails' do
    admin!(email: 'real-person@sanctuary.computer')
    g3d_with_snapshot!([june_entry('real-person@sanctuary.computer')])

    err = mcp_payload(Mcp::GetPersonMetricsTool.call(email: 'nobody@example.com', server_context: {}))
    assert_includes err['error'], 'nobody@example.com'
    refute_includes err['error'], 'real-person@sanctuary.computer', 'must not enumerate other people'
  end

  test 'email resolution is case-insensitive' do
    admin = admin!
    g3d_with_snapshot!([june_entry(admin.email)])
    AdminUser.any_instance.stubs(:skill_tree_points_on_date).returns(1)

    payload = mcp_payload(Mcp::GetPersonMetricsTool.call(email: 'Ada@Sanctuary.Computer', server_context: {}))
    assert_equal admin.email, payload['person']
  end

  test 'invalid gradation errors listing valid values' do
    admin = admin!
    err = mcp_payload(Mcp::GetPersonMetricsTool.call(email: admin.email, gradation: 'weekly', server_context: {}))
    assert_includes err['error'], "Invalid gradation 'weekly'"
    assert_includes err['error'], 'trailing_3_months'
  end

  test 'periods clamps to at most 24' do
    admin = admin!
    g3d_with_snapshot!([june_entry(admin.email)])
    AdminUser.any_instance.stubs(:skill_tree_points_on_date).returns(1)

    payload = mcp_payload(Mcp::GetPersonMetricsTool.call(email: admin.email, periods: 500, server_context: {}))
    assert_equal 24, payload['periods'].length
  end
end
