require 'test_helper'

class Stacks::FinancialOutlookTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  PERSON = { first_name: 'Secretia', last_name: 'Personname', email: 'secretia.personname@example.com' }.freeze

  setup do
    travel_to Time.zone.parse('2026-09-29 12:00:00')
    _tb, @g3d = make_studio!
    ForecastPerson.create!(forecast_id: 9001, **PERSON)
  end

  def runn_project!(id, name, pricing: 'tm', confirmed: true, budget: nil)
    RunnProject.create!(runn_id: id, name: name, pricing_model: pricing, is_confirmed: confirmed, is_template: false, is_archived: false, budget: budget)
  end

  def runn_assign!(project, from, to, hours_per_day: 8, placeholder: false, billable: true, person_id: 1)
    RunnAssignment.create!(runn_id: RunnAssignment.count + 1000, person_id: person_id, project_id: project.runn_id,
                           start_date: from, end_date: to, minutes_per_day: hours_per_day * 60,
                           is_placeholder: placeholder, is_billable: billable)
  end

  def tracker_for!(runn_project, rate:)
    fp, _fc = make_forecast_project!("Client of #{runn_project.name}", "#{runn_project.name} FP")
    fp.update!(tags: ["#{rate}p/h"])
    tracker = make_project_tracker!([fp])
    tracker.update!(runn_project_id: runn_project.runn_id)
    tracker
  end

  def month_entry(label, from, to, income, okrs = {})
    { 'label' => label, 'period_starts_at' => from, 'period_ends_at' => to,
      'accrual' => { 'datapoints' => { 'income' => { 'value' => income } }, 'okrs' => okrs } }
  end

  test 'booked: Runn hours × project rate per month; fixed-price listed not priced; tentative apart; retainers capped' do
    acme = runn_project!(1, 'Acme Site')
    tracker_for!(acme, rate: 100)
    retainer = runn_project!(2, 'Beta Retainer')
    tracker_for!(retainer, rate: 100).update!(monthly_budget_low_end: 1000, monthly_budget_high_end: 1000)
    fixed = runn_project!(3, 'Gamma Launch', pricing: 'fp', budget: 90_000)
    internal = runn_project!(4, 'Internal Ops', pricing: 'nb')
    pitch = runn_project!(5, 'Delta Pitch', confirmed: false)
    unlinked = runn_project!(6, 'Epsilon Audit')

    runn_assign!(acme, Date.new(2026, 10, 1), Date.new(2026, 10, 2))          # Thu+Fri: 16h × $100 = $1,600
    runn_assign!(retainer, Date.new(2026, 10, 1), Date.new(2026, 10, 2))      # $1,600, capped to $1,000
    runn_assign!(acme, Date.new(2026, 10, 3), Date.new(2026, 10, 4))          # a weekend: nothing
    runn_assign!(acme, Date.new(2026, 10, 5), Date.new(2026, 10, 5), placeholder: true) # tentative $800
    runn_assign!(pitch, Date.new(2026, 10, 5), Date.new(2026, 10, 5))         # unconfirmed: tentative 8h × $175
    runn_assign!(fixed, Date.new(2026, 10, 5), Date.new(2026, 10, 9))
    runn_assign!(internal, Date.new(2026, 10, 5), Date.new(2026, 10, 9))
    runn_assign!(acme, Date.new(2026, 10, 6), Date.new(2026, 10, 6), billable: false)
    runn_assign!(unlinked, Date.new(2026, 10, 7), Date.new(2026, 10, 7))      # default rate $175 × 8h = $1,400

    out = Stacks::FinancialOutlook.new.call
    oct = out[:booked][:months].find { |m| m[:month] == '2026-10' }
    assert_equal 4000, oct[:booked_usd]
    assert_equal 600, oct[:retainer_cap_applied_usd]
    assert_equal 2200, oct[:tentative_usd]
    assert_equal [{ project: 'Acme Site', booked_usd: 1600 }, { project: 'Epsilon Audit', booked_usd: 1400 }, { project: 'Beta Retainer', booked_usd: 1000 }], oct[:top_projects]
    assert_equal [{ project: 'Gamma Launch', budget_usd: 90_000 }], out[:booked][:fixed_price_not_priced_hourly]
    assert_equal 2, out[:booked][:priced_at_default_rate_projects]
    assert_match(/booked hours × project rate, before discounts\/caps/, out[:booked][:basis])
    assert_equal '2026-09-29', out[:booked][:months].first[:partial_from], 'the current month counts only what is left'
  end

  test 'actuals are accrual Income from the g3d snapshot; the target only when an Income OKR stores one' do
    @g3d.update!(snapshot: { 'month' => [
      month_entry('July, 2026', '07/01/2026', '07/31/2026', 500_000),
      month_entry('August, 2026', '08/01/2026', '08/31/2026', 550_000, { 'Monthly Income' => { 'target' => 600_000, 'health' => 'at_risk' } }),
      month_entry('September, 2026', '09/01/2026', '09/30/2026', 100_000),
    ] })
    out = Stacks::FinancialOutlook.new.call
    assert_equal [{ month: '2026-07', income_usd: 500_000 }, { month: '2026-08', income_usd: 550_000 }], out[:actuals][:months].last(2)
    refute out[:actuals][:months].any? { |m| m[:month] == '2026-09' }, 'an open month is not an actual'
    assert_match(/accrual/, out[:actuals][:basis])
    assert_nil out[:target][:income_usd], 'no Income OKR row, no target'

    Okr.create!(name: 'Monthly Income', datapoint: :income, operator: :greater_than)
    t = Stacks::FinancialOutlook.new.call[:target]
    assert_equal 600_000, t[:income_usd]
    assert_match(/August, 2026/, t[:basis])
  end

  def pnl!(qa, month, rows)
    QboProfitAndLossReport.create!(qbo_account: qa, starts_at: month, ends_at: month.end_of_month, data: { 'accrual' => { 'rows' => rows }, 'cash' => { 'rows' => [] } })
  end

  def rows(software:, rent:, salaries: 50_000)
    [['Income', nil], ['4000 Services', '100000'], ['Total Income', '100000'],
     ['Cost of Goods Sold', nil], ['5005 Occupancy Costs', nil], ['[NYC] Rent Expense', rent.to_s], ['Total 5005 Occupancy Costs', rent.to_s],
     ['5020 Operations', nil], ['[NYC] Instructors', '4000'], ['[NYC] Facilities Staff & Management', '3000'], ['Total 5020 Operations', '7000'],
     ['Total Cost of Goods Sold', '0'], ['Gross Profit', '0'],
     ['Expenses', nil], ['6000 Payroll Expenses', nil], ['Salaries', salaries.to_s], ['Health Insurance', '9000'], ['Total 6000 Payroll Expenses', '0'],
     ['8000 General and Administrative Expenses', nil], ['8015 Carbon Offset Contributions', '10'], ['Total 8015 Carbon Offset Contributions', '10'],
     ['[NYC] Software and Subscriptions', software.to_s], ['[BK] Software and Subscriptions', software.to_s],
     ['Management Fee Expense', '75000'], ['Subcontractors', '20000'],
     ['Total 8000 General and Administrative Expenses', '0'], ['Total Expenses', '0'], ['Net Operating Income', '0']]
  end

  test 'spend: accrual P&L categories, all entities combined, locations merged, people costs and intercompany out' do
    [qbo_accounts(:one), qbo_accounts(:two)].each do |qa|
      (6..8).each { |mo| pnl!(qa, Date.new(2026, mo, 1), rows(software: 200, rent: 1000)) }
      (3..5).each { |mo| pnl!(qa, Date.new(2026, mo, 1), rows(software: 100, rent: 1000)) }
    end
    s = Stacks::FinancialOutlook.new.call[:spend]
    # per entity per month: rent 1000 + software 2×200 + carbon 10 = 1410; × 2 entities × 3 months
    assert_equal({ from: '2026-06-01', to: '2026-08-31', total_usd: 8460 }, s[:last])
    assert_equal 7260, s[:prior][:total_usd]
    assert_equal [{ category: 'Software and Subscriptions', last_usd: 2400, prior_usd: 1200, change_usd: 1200 }], s[:top_movers]
    assert_match(/excludes payroll, benefits, contractors, payments to people and intercompany/, s[:basis])
    assert_nil s[:months_without_a_p_and_l]
  end

  test 'the people-cost exclusion table covers payroll, benefits, contractors and intercompany, not ordinary costs' do
    ex = ->(*l) { Stacks::PeopleCostAccounts.excluded?(*l) }
    ['Salaries', 'Officer Compensation', 'Health Insurance', 'Guideline 401k', 'Contract Labor', 'Subcontractors',
     'Management Fee Expense', 'Due to garden3d', '[NYC] Instructors', 'Payroll Taxes', 'Profit Share Payouts',
     'Professional Consulting', 'Misc Payments - Client Services', 'Misc Payments Offset - Client Services'].each { |n| assert ex.call(n), n }
    assert ex.call('Anything', '6000 Payroll Expenses'), 'a parent header excludes its children'
    ['Software and Subscriptions', 'Rent Expense', 'Marketing and Advertising', 'Electricity', 'Carbon Offset Contributions'].each { |n| refute ex.call(n), n }
  end

  test 'no person is ever named in the output' do
    RunnPerson.create!(runn_id: 77, first_name: PERSON[:first_name], last_name: PERSON[:last_name], email: PERSON[:email])
    acme = runn_project!(1, 'Acme Site')
    runn_assign!(acme, Date.new(2026, 10, 1), Date.new(2026, 10, 2), person_id: 77)
    pnl!(qbo_accounts(:one), Date.new(2026, 8, 1), [['Expenses', nil], ['Secretia Personname Salary', '9000'], ['Payouts', nil], ['Secretia Personname', '5000'], ['Total Payouts', '5000'], ['Total Expenses', '0']])
    json = Mcp::GetFinancialOutlookTool.call(server_context: {}).content.first[:text]
    PERSON.each_value { |v| refute_includes json, v }
    refute_includes json, 'Secretia'
    assert_includes json, 'Acme'
  end
end
