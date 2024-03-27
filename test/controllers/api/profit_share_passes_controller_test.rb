require 'test_helper'

class Api::ProfitSharePassesControllerTest < ActionDispatch::IntegrationTest
  test "for each pass, appends total_psu_issued for that year to the response" do
    pass = ProfitSharePass.create!(efficiency_cap: 1.2, snapshot: {"inputs": {"actuals": {"gross_payroll": 653351, "gross_revenue": 1168836, "gross_benefits": 0, "gross_expenses": 304610, "gross_subcontractors": 0}, "pre_spent": 0, "fica_tax_rate": 0, "efficiency_cap": 1.6, "total_psu_issued": 139, "desired_buffer_months": 1, "internals_budget_multiplier": 0.5, "projected_monthly_cost_of_doing_business": 84000}, "finalized_at": "2018-12-15T00:00:00.000+00:00"})
    Studio.create!({
      name: "garden3d",
      mini_name: "g3d"
    })
    get "/api/profit_share_passes"

    assert_response :success

    expected = [{ id: pass.id, 
    desired_buffer_months: pass.snapshot.dig("inputs", "desired_buffer_months").to_f,
    # Note that we expect the efficiency cap from the snapshot instead of the top-level one
    efficiency_cap: pass.snapshot.dig("inputs", "efficiency_cap").to_f,
    fica_tax_rate: pass.snapshot.dig("inputs", "fica_tax_rate").to_f,
    gross_expenses: pass.snapshot.dig("inputs", "actuals", "gross_expenses").to_f,
    gross_payroll: pass.snapshot.dig("inputs", "actuals", "gross_payroll").to_f,
    gross_revenue: pass.snapshot.dig("inputs", "actuals", "gross_revenue").to_f,
    internals_budget_multiplier: pass.snapshot.dig("inputs", "internals_budget_multiplier").to_f,
    projected_monthly_cost_of_doing_business: pass.snapshot.dig("inputs", "projected_monthly_cost_of_doing_business").to_f,
    total_psu_issued: pass.total_psu_issued.round,
    year: pass.created_at.year }].to_json
    assert_equal(expected, @response.body)
  end

  test "returns empty list when no passes exist" do
    Studio.create!({
      name: "garden3d",
      mini_name: "g3d"
    })
    get "/api/profit_share_passes"

    assert_response :success
    assert_equal([].to_json, @response.body)
  end

  test "returns empty list when no finalized passes exist (snapshot is nil)" do
    pass = ProfitSharePass.create!(snapshot: nil)
    Studio.create!({
      name: "garden3d",
      mini_name: "g3d"
    })
    get "/api/profit_share_passes"

    assert_response :success
    assert_equal([].to_json, @response.body)
  end
end
