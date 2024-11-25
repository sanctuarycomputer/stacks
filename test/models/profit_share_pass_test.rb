require 'test_helper'

class ProfitSharePassTest < ActiveSupport::TestCase
  test "it works when the users are still employed and the project tracker is successful" do
    profit_share_pass = ProfitSharePass.ensure_exists!

    studio, g3d = make_studio!
    admin_user = make_admin_user!(studio, Date.new(2020, 1, 1), nil)
    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    # Assign the user from the start of the project
    project_kickoff = Date.today - 1.week
    ProjectLeadPeriod.create!({
      project_tracker: project_tracker,
      admin_user: admin_user,
      studio: studio,
      started_at: project_kickoff
    })

    assignment_one = ForecastAssignment.create!({
      forecast_id: 1,
      start_date: project_kickoff,
      end_date: project_kickoff + 1.week,
      forecast_person: admin_user.forecast_person,
      forecast_project: forecast_project
    })

    project_tracker.generate_snapshot!
    assert_equal(project_tracker.considered_successful?, true)

    pldbau = profit_share_pass.project_leadership_days_by_admin_user[admin_user]
    assert_equal(pldbau.values.first, {
      days: 8,
      considered_successful: true
    })

    assert_equal(profit_share_pass.total_effective_project_leadership_days, 8)
    assert_equal(profit_share_pass.total_effective_successful_project_leadership_days, 8)
  end

  test "it only counts role days from the day the role started (not previous assignments)" do
    profit_share_pass = ProfitSharePass.ensure_exists!

    studio, g3d = make_studio!
    admin_user = make_admin_user!(studio, Date.new(2020, 1, 1), nil)
    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    # Assign the user from the start of the project
    project_kickoff = Date.today - 1.week
    role = ProjectLeadPeriod.create!({
      project_tracker: project_tracker,
      admin_user: admin_user,
      studio: studio,
      started_at: project_kickoff
    })

    assignment_one = ForecastAssignment.create!({
      forecast_id: 1,
      start_date: project_kickoff - 1.week,
      end_date: project_kickoff + 2.days,
      forecast_person: admin_user.forecast_person,
      forecast_project: forecast_project
    })

    project_tracker.generate_snapshot!
    assert_equal(project_tracker.considered_successful?, true)

    expected_effective_role_days = (role.started_at..assignment_one.end_date).count

    pldbau = profit_share_pass.project_leadership_days_by_admin_user[admin_user]
    assert_equal(pldbau.values.first, {
      days: expected_effective_role_days,
      considered_successful: true
    })

    assert_equal(profit_share_pass.total_effective_project_leadership_days, expected_effective_role_days)
    assert_equal(profit_share_pass.total_effective_successful_project_leadership_days, expected_effective_role_days)
  end

  test "it only counts role days up until the role ended (not future assignments)" do
    profit_share_pass = ProfitSharePass.ensure_exists!

    studio, g3d = make_studio!
    admin_user = make_admin_user!(studio, Date.new(2020, 1, 1), nil)
    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    # Assign the user from the start of the project
    project_kickoff = Date.today - 1.month
    role = ProjectLeadPeriod.create!({
      project_tracker: project_tracker,
      admin_user: admin_user,
      studio: studio,
      started_at: project_kickoff,
      ended_at: project_kickoff + 1.week,
    })

    # Assignment starts 2 days after the role assignment
    assignment_one = ForecastAssignment.create!({
      forecast_id: 1,
      start_date: project_kickoff + 2.days,
      end_date: project_kickoff + 1.month,
      forecast_person: admin_user.forecast_person,
      forecast_project: forecast_project
    })

    project_tracker.generate_snapshot!
    assert_equal(project_tracker.considered_successful?, true)

    expected_effective_role_days = (assignment_one.start_date..role.ended_at).count

    pldbau = profit_share_pass.project_leadership_days_by_admin_user[admin_user]
    assert_equal(pldbau.values.first, {
      days: expected_effective_role_days,
      considered_successful: true
    })

    assert_equal(profit_share_pass.total_effective_project_leadership_days, expected_effective_role_days)
    assert_equal(profit_share_pass.total_effective_successful_project_leadership_days, expected_effective_role_days)
  end

  test "it does not include admin users who've left the company this year" do
    profit_share_pass = ProfitSharePass.ensure_exists!
    studio, g3d = make_studio!

    # Project Lead quits in February of the current year
    project_lead = make_admin_user!(studio, Date.new(2020, 1, 1), profit_share_pass.created_at.beginning_of_year + 1.month)
    ic = make_admin_user!(studio, Date.new(2020, 1, 1), nil, "tonya@thoughtbot.com")

    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    # This project started at the start of this year
    project_kickoff = profit_share_pass.created_at.beginning_of_year
    role = ProjectLeadPeriod.create!({
      project_tracker: project_tracker,
      admin_user: project_lead,
      studio: studio,
      started_at: profit_share_pass.created_at.beginning_of_year,
      ended_at: nil
    })

    pldbau = profit_share_pass.project_leadership_days_by_admin_user
    assert_nil(pldbau[project_lead])
  end

  test "it does not distribute PSU to leads of unsuccessful projects" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: DateTime.now - 2.years,
      leadership_psu_pool_cap: 240,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    # Both projects started at the start of this year
    project_kickoff = profit_share_pass.created_at.beginning_of_year

    studio, g3d = make_studio!

    project_lead_1 = make_admin_user!(studio, Date.new(2020, 1, 1))
    forecast_project_1, forecast_client_1 = make_forecast_project!
    successful_project = make_project_tracker!([forecast_project_1])

    ProjectLeadPeriod.create!({
      project_tracker: successful_project,
      admin_user: project_lead_1,
      studio: studio,
      started_at: project_kickoff,
      ended_at: nil
    })

    assignment_1 = ForecastAssignment.create!({
      forecast_id: 1,
      start_date: project_kickoff,
      end_date: project_kickoff + 1.day,
      forecast_person: project_lead_1.forecast_person,
      forecast_project: forecast_project_1
    })

    project_lead_2 = make_admin_user!(studio, Date.new(2020, 1, 1), nil, "tonya@thoughtbot.com")
    forecast_project_2, _ = make_forecast_project!
    unsuccessful_project = make_project_tracker!([forecast_project_2])

    ProjectLeadPeriod.create!({
      project_tracker: unsuccessful_project,
      admin_user: project_lead_1,
      studio: studio,
      started_at: project_kickoff,
      ended_at: nil
    })

    assignment_2 = ForecastAssignment.create!({
      forecast_id: 2,
      start_date: project_kickoff,
      end_date: project_kickoff + 1.day,
      forecast_person: project_lead_2.forecast_person,
      forecast_project: forecast_project_2
    })

    # Now, run snapshots
    Stacks::DailyFinancialSnapshotter.snapshot_all!
    successful_project.generate_snapshot!

    # Mock that we've invoiced the spend completely for successful_project
    successful_project.update!(
      snapshot: successful_project.snapshot.merge({
        "invoiced_with_running_spend_total" => successful_project.snapshot["spend_total"]
      })
    )

    # Mock but for unsuccessful project, we've only invoiced cost...
    unsuccessful_project.update!(
      snapshot: successful_project.snapshot.merge({
        "invoiced_with_running_spend_total" => unsuccessful_project.estimated_cost("cash")
      })
    )

    assert(successful_project.considered_successful?)
    refute(unsuccessful_project.considered_successful?)

    assert_equal(profit_share_pass.total_effective_project_leadership_days, 4)
    assert_equal(profit_share_pass.total_effective_successful_project_leadership_days, 2)

    assert_equal(
      profit_share_pass.awarded_project_leadership_psu_proportion_for_admin_user(project_lead_1),
      1
    )
    assert_equal(
      profit_share_pass.awarded_project_leadership_psu_proportion_for_admin_user(project_lead_2),
      0
    )
  end

  test "it enables leadership PSU when leadership_psu_pool_cap > 0" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: DateTime.now - 2.years,
      leadership_psu_pool_cap: 0,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    refute(profit_share_pass.includes_leadership_psu_pool?)

    profit_share_pass.update({
      leadership_psu_pool_cap: 240
    })

    assert(profit_share_pass.includes_leadership_psu_pool?)
  end

  test "it awards PSU to the leadership pool based on core g3d performance" do
    profit_share_pass = ProfitSharePass.create!({
      leadership_psu_pool_cap: 240,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    xxix = Studio.create!({
      name: "XXIX",
      accounting_prefix: "Design",
      mini_name: "xxix",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs": {
              "Successful Projects":
                {"value"=>80.0, "target"=>"85.0", "tolerance"=>"15.0"},
              "Successful Proposals":
                {"value"=>33.33, "target"=>"34.0", "tolerance"=>"10.0"}
            }
          }
        }]
      }
    })

    sanctu = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sanctu",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs": {
              "Successful Projects":
                {"value": 80.0, "target": "85.0", "tolerance": "15.0"},
              "Successful Proposals":
                {"value": 33.33, "target": "34.0", "tolerance": "10.0"}
            }
          }
        }]
      }
    })

    g3d = Studio.create!({
      name: "garden3d",
      accounting_prefix: "",
      mini_name: "g3d",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs_excluding_reinvestment": {
              "Revenue Growth":
                {"value": -17.39, "target": "10", "tolerance": "5"},
              "Lead Growth":
                {"value": -47.82, "target": "10", "tolerance": "5"},
              "Profit Margin":
                {"value": 24.625, "target": "32.0", "tolerance": "15.0"},
              "Workplace Satisfaction":
                {"value": 3.49, "target": "4", "tolerance": "1"}
            },
            "datapoints_excluding_reinvestment": {
              "revenue": { "value": 4795349.56 },
              "lead_count": { "value": 96 }
            }
          }
        }, {
          "label": (Date.today.year - 1).to_s,
          "accrual": {
            "datapoints_excluding_reinvestment": {
              "revenue": { "value": 5804947.0 },
              "lead_count": { "value": 184 }
            }
          }
        }]
      }
    })

    assert_equal(profit_share_pass.leadership_psu_pool["total_awarded"].to_i, 125)
  end

  test "it doesn't award PSU when all OKRs fail" do
    profit_share_pass = ProfitSharePass.create!({
      leadership_psu_pool_cap: 240,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    xxix = Studio.create!({
      name: "XXIX",
      accounting_prefix: "Design",
      mini_name: "xxix",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs": {
              "Successful Projects":
                {"value": 0, "target": "85.0", "tolerance": "15.0"},
              "Successful Proposals":
                {"value": 0, "target": "34.0", "tolerance": "10.0"}
            }
          }
        }]
      }
    })

    sanctu = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sanctu",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs": {
              "Successful Projects":
                {"value": 0, "target": "85.0", "tolerance": "15.0"},
              "Successful Proposals":
                {"value": 0, "target": "34.0", "tolerance": "10.0"}
            }
          }
        }]
      }
    })

    g3d = Studio.create!({
      name: "garden3d",
      accounting_prefix: "",
      mini_name: "g3d",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs_excluding_reinvestment": {
              "Revenue Growth":
                {"value": 0, "target": "10", "tolerance": "5"},
              "Lead Growth":
                {"value": 0, "target": "10", "tolerance": "5"},
              "Profit Margin":
                {"value": 0, "target": "32.0", "tolerance": "15.0"},
              "Workplace Satisfaction":
                {"value": 0, "target": "4", "tolerance": "1"}
            },
            "datapoints_excluding_reinvestment": {
              "revenue": { "value": 0 },
              "lead_count": { "value": 0 }
            }
          }
        }, {
          "label": (Date.today.year - 1).to_s,
          "accrual": {
            "datapoints_excluding_reinvestment": {
              "revenue": { "value": 5804947.0 },
              "lead_count": { "value": 184 }
            }
          }
        }]
      }
    })

    assert_equal(profit_share_pass.leadership_psu_pool["total_awarded"], 0)
  end

  test "it awards the full leadership_psu_pool_cap when all OKRs are met" do
    profit_share_pass = ProfitSharePass.create!({
      leadership_psu_pool_cap: 240,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    xxix = Studio.create!({
      name: "XXIX",
      accounting_prefix: "Design",
      mini_name: "xxix",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs": {
              "Successful Projects":
                {"value": 85, "target": "85.0", "tolerance": "15.0"},
              "Successful Proposals":
                {"value": 34, "target": "34.0", "tolerance": "10.0"}
            }
          }
        }]
      }
    })

    sanctu = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sanctu",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs": {
              "Successful Projects":
                {"value": 85, "target": "85.0", "tolerance": "15.0"},
              "Successful Proposals":
                {"value": 34, "target": "34.0", "tolerance": "10.0"}
            }
          }
        }]
      }
    })

    g3d = Studio.create!({
      name: "garden3d",
      accounting_prefix: "",
      mini_name: "g3d",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs_excluding_reinvestment": {
              "Revenue Growth":
                {"value": 10, "target": "10", "tolerance": "5"},
              "Lead Growth":
                {"value": 10, "target": "10", "tolerance": "5"},
              "Profit Margin":
                {"value": 32, "target": "32.0", "tolerance": "15.0"},
              "Workplace Satisfaction":
                {"value": 4, "target": "4", "tolerance": "1"}
            },
            "datapoints_excluding_reinvestment": {
              "revenue": { "value": 0 },
              "lead_count": { "value": 0 }
            }
          }
        }, {
          "label": (Date.today.year - 1).to_s,
          "accrual": {
            "datapoints_excluding_reinvestment": {
              "revenue": { "value": 5804947.0 },
              "lead_count": { "value": 184 }
            }
          }
        }]
      }
    })

    assert_equal(profit_share_pass.leadership_psu_pool["total_awarded"], profit_share_pass.leadership_psu_pool_cap)
  end


  test "it doesn't award more than the leadership_psu_pool_cap when all OKRs are exceptional" do
    profit_share_pass = ProfitSharePass.create!({
      leadership_psu_pool_cap: 240,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    xxix = Studio.create!({
      name: "XXIX",
      accounting_prefix: "Design",
      mini_name: "xxix",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs": {
              "Successful Projects":
                {"value": 100, "target": "85.0", "tolerance": "15.0"},
              "Successful Proposals":
                {"value": 100, "target": "34.0", "tolerance": "10.0"}
            }
          }
        }]
      }
    })

    sanctu = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sanctu",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs": {
              "Successful Projects":
                {"value": 100, "target": "85.0", "tolerance": "15.0"},
              "Successful Proposals":
                {"value": 100, "target": "34.0", "tolerance": "10.0"}
            }
          }
        }]
      }
    })

    g3d = Studio.create!({
      name: "garden3d",
      accounting_prefix: "",
      mini_name: "g3d",
      snapshot: {
        "year": [{
          "label": "YTD",
          "accrual": {
            "okrs_excluding_reinvestment": {
              "Revenue Growth":
                {"value": 15, "target": "10", "tolerance": "5"},
              "Lead Growth":
                {"value": 15, "target": "10", "tolerance": "5"},
              "Profit Margin":
                {"value": 47, "target": "32.0", "tolerance": "15.0"},
              "Workplace Satisfaction":
                {"value": 5, "target": "4", "tolerance": "1"}
            },
            "datapoints_excluding_reinvestment": {
              "revenue": { "value": 0 },
              "lead_count": { "value": 0 }
            }
          }
        }, {
          "label": (Date.today.year - 1).to_s,
          "accrual": {
            "datapoints_excluding_reinvestment": {
              "revenue": { "value": 5804947.0 },
              "lead_count": { "value": 184 }
            }
          }
        }]
      }
    })

    assert_equal(profit_share_pass.leadership_psu_pool["total_awarded"], profit_share_pass.leadership_psu_pool_cap)
  end



end
