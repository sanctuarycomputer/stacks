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

  test "if an AdminUser starts their employment after a project begins, their role days do not count from before they joined" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    studio, g3d = make_studio!
    admin_user = make_admin_user!(studio, profit_share_pass.created_at.to_date + 1.month, nil, "ilana@thoughtbot.com")
    admin_user_2 = make_admin_user!(studio, profit_share_pass.created_at.to_date)
    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    # Assign the user from the start of the project
    project_kickoff = profit_share_pass.created_at.to_date
    ProjectLeadPeriod.create!({
      project_tracker: project_tracker,
      admin_user: admin_user,
      studio: studio,
      started_at: nil
    })

    assignment_one = ForecastAssignment.create!({
      forecast_id: 1,
      start_date: project_kickoff,
      end_date: project_kickoff + 1.day,
      forecast_person: admin_user_2.forecast_person,
      forecast_project: forecast_project
    })

    assignment_two = ForecastAssignment.create!({
      forecast_id: 2,
      start_date: admin_user.start_date,
      end_date: admin_user.start_date + 1.day,
      forecast_person: admin_user_2.forecast_person,
      forecast_project: forecast_project
    })

    pldbau = profit_share_pass.project_leadership_days_by_admin_user[admin_user]
    assert_equal(pldbau.values.first[:days], (assignment_two.start_date..assignment_two.end_date).count)
  end

  test "if an AdminUser quites their employment before a project ends, they aren't counted" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    studio, g3d = make_studio!
    admin_user = make_admin_user!(studio, profit_share_pass.created_at.to_date, profit_share_pass.created_at.to_date + 1.month, "ilana@thoughtbot.com")
    admin_user_2 = make_admin_user!(studio, profit_share_pass.created_at.to_date)
    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    # Assign the user from the start of the project
    project_kickoff = profit_share_pass.created_at.to_date
    ProjectLeadPeriod.create!({
      project_tracker: project_tracker,
      admin_user: admin_user,
      studio: studio,
      started_at: nil
    })

    assignment_one = ForecastAssignment.create!({
      forecast_id: 1,
      start_date: project_kickoff,
      end_date: project_kickoff + 1.day,
      forecast_person: admin_user_2.forecast_person,
      forecast_project: forecast_project
    })

    assignment_two = ForecastAssignment.create!({
      forecast_id: 2,
      start_date: profit_share_pass.created_at.to_date + 1.month,
      end_date: profit_share_pass.created_at.to_date + 1.month + 1.day,
      forecast_person: admin_user_2.forecast_person,
      forecast_project: forecast_project
    })

    assert_nil profit_share_pass.project_leadership_days_by_admin_user[admin_user]
  end

  test "it only counts role days from the day the role started (not previous assignments)" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: DateTime.now - 2.years,
      leadership_psu_pool_cap: 240,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    studio, g3d = make_studio!
    admin_user = make_admin_user!(studio, Date.new(2020, 1, 1), nil)
    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    # Assign the user from the start of the project
    project_kickoff = profit_share_pass.created_at.to_date - 1.week
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

    project_tracker.update!(
      snapshot: project_tracker.snapshot.merge({
        "invoiced_with_running_spend_total" => project_tracker.snapshot["spend_total"]
      })
    )
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
    profit_share_pass = ProfitSharePass.create!({
      created_at: DateTime.now - 2.years,
      leadership_psu_pool_cap: 240,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    studio, g3d = make_studio!
    admin_user = make_admin_user!(studio, Date.new(2020, 1, 1), nil)
    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    # Assign the user from the start of the project
    project_kickoff = profit_share_pass.created_at.to_date - 1.month
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
      created_at: Date.new(2028, 1, 1),
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

    assert_equal(profit_share_pass.leadership_psu_pool["total_claimable"].to_i, 125)
  end

  test "it doesn't award PSU when all OKRs fail" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
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

    assert_equal(profit_share_pass.leadership_psu_pool["total_claimable"], 0)
  end

  test "it awards the full leadership_psu_pool_cap when all OKRs are met" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
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

    assert_equal(profit_share_pass.leadership_psu_pool["total_claimable"], profit_share_pass.leadership_psu_pool_cap)
  end


  test "it doesn't award more than the leadership_psu_pool_cap when all OKRs are exceptional" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
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

    assert_equal(profit_share_pass.leadership_psu_pool["total_claimable"], profit_share_pass.leadership_psu_pool_cap)
  end

  test "it correctly distributes project leadership PSU based on percentage split" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2023, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30  # 30% to project leaders
    })

    xxix, sanctu, g3d = make_g3d_studios!
    project_lead = make_admin_user!(xxix, Date.new(2020, 1, 1))

    # Setup a successful project
    forecast_project, _ = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    # Create project lead role for entire year
    ProjectLeadPeriod.create!({
      project_tracker: project_tracker,
      admin_user: project_lead,
      studio: xxix,
      started_at: profit_share_pass.created_at.beginning_of_year
    })

    assignment_one = ForecastAssignment.create!({
      forecast_id: 1,
      start_date: profit_share_pass.created_at.beginning_of_year,
      end_date: profit_share_pass.created_at.beginning_of_year + 1.day,
      forecast_person: project_lead.forecast_person,
      forecast_project: forecast_project
    })

    # Setup successful project conditions
    project_tracker.generate_snapshot!
    project_tracker.update!(
      snapshot: project_tracker.snapshot.merge({
        "invoiced_with_running_spend_total" => project_tracker.snapshot["spend_total"]
      })
    )

    psu_distributions = profit_share_pass.psu_distributions
    distribution = psu_distributions.find { |p| p[:admin_user] == project_lead }
    assert_equal distribution[:project_leadership], 30.0 # Should get 30% of the leadership pool (30 PSU)
  end

  test "it correctly distributes collective leadership PSU based on percentage split" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30  # 70% to collective leaders
    })

    xxix, sanctu, g3d = make_g3d_studios!
    collective_leader = make_admin_user!(xxix, Date.new(2020, 1, 1))

    # Setup collective role for entire year
    role = CollectiveRole.create!(
      name: "General Manager",
      leadership_psu_pool_weighting: 1.0,
      notion_link: "https://notion.so/123"
    )
    CollectiveRoleHolderPeriod.create!({
      collective_role: role,
      admin_user: collective_leader,
      started_at: profit_share_pass.created_at.beginning_of_year
    })

    psu_distributions = profit_share_pass.psu_distributions
    distribution = psu_distributions.find { |p| p[:admin_user] == collective_leader }
    assert_equal distribution[:collective_leadership], 70.0 # Should get 70% of the leadership pool (70 PSU)
  end

  test "it correctly splits PSU between multiple collective leaders based on role weighting" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    xxix, sanctu, g3d = make_g3d_studios!
    leader_1 = make_admin_user!(sanctu, Date.new(2020, 1, 1), nil, "michael@sanctuary.computer")
    leader_2 = make_admin_user!(xxix, Date.new(2020, 1, 1), nil, "jacob@xxix.co")

    # Setup two collective roles with different weightings
    role_1 = CollectiveRole.create!(
      name: "General Manager",
      leadership_psu_pool_weighting: 1.0,
      notion_link: "https://notion.so/123"
    )
    role_2 = CollectiveRole.create!(
      name: "Director",
      leadership_psu_pool_weighting: 0.5,
      notion_link: "https://notion.so/123"
    )

    CollectiveRoleHolderPeriod.create!({
      collective_role: role_1,
      admin_user: leader_1,
      started_at: profit_share_pass.created_at.beginning_of_year
    })

    CollectiveRoleHolderPeriod.create!({
      collective_role: role_2,
      admin_user: leader_2,
      started_at: profit_share_pass.created_at.beginning_of_year
    })

    psu_distributions = profit_share_pass.psu_distributions
    leader_1_distro = psu_distributions.find { |p| p[:admin_user] == leader_1 }
    leader_2_distro = psu_distributions.find { |p| p[:admin_user] == leader_2 }

    # Leader 1 should get 2/3 of the 70% collective pool (46.67 PSU)
    # Leader 2 should get 1/3 of the 70% collective pool (23.33 PSU)
    assert_equal leader_1_distro[:collective_leadership].round(2), 46.67
    assert_equal leader_2_distro[:collective_leadership].round(2), 23.33
  end

  test "it correctly calculates maximum possible collective leadership weighted days" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    # Create collective roles with different weightings
    gm_role = CollectiveRole.create!(
      name: "General Manager",
      leadership_psu_pool_weighting: 1.0,
      created_at: Date.new(2023, 1, 1),
      notion_link: "https://notion.so/123"
    )

    director_role = CollectiveRole.create!(
      name: "Director",
      leadership_psu_pool_weighting: 0.5,
      created_at: Date.new(2023, 1, 1),
      notion_link: "https://notion.so/123"
    )

    # For a non-leap year, should be:
    # (365 days * 1.0 weighting) + (365 days * 0.5 weighting) = 547.5 weighted days
    days_in_year = Date.new(profit_share_pass.created_at.year, 12, 31).yday
    expected_max_days = (days_in_year * 1.0) + (days_in_year * 0.5)

    assert_equal(
      profit_share_pass.send(:max_possible_collective_leadership_weighted_days_for_year),
      expected_max_days
    )
  end

  test "it does not redistribute unclaimed collective role PSU to other role holders" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    xxix, sanctu, g3d = make_g3d_studios!
    leader = make_admin_user!(sanctu, Date.new(2020, 1, 1))

    # Create two roles, but only assign one
    gm_role = CollectiveRole.create!(
      name: "General Manager",
      leadership_psu_pool_weighting: 1.0,
      notion_link: "https://notion.so/123"
    )

    # Create another role that no one claims
    unclaimed_role = CollectiveRole.create!(
      name: "Unclaimed Role",
      leadership_psu_pool_weighting: 1.0,
      notion_link: "https://notion.so/123"
    )

    CollectiveRoleHolderPeriod.create!({
      collective_role: gm_role,
      admin_user: leader,
      started_at: profit_share_pass.created_at.beginning_of_year
    })

    psu_distributions = profit_share_pass.psu_distributions
    distribution = psu_distributions.find { |p| p[:admin_user] == leader }
    # Leader should only get their share of the 70% collective pool based on their role's weighting
    # With two equal-weighted roles (1.0 each), they should get 35 PSU (half of 70)
    assert_equal distribution[:collective_leadership], 35.0
  end

  test "it correctly sums non-contiguous periods for collective role holders" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    xxix, sanctu, g3d = make_g3d_studios!
    leader = make_admin_user!(sanctu, Date.new(2020, 1, 1))

    role = CollectiveRole.create!(
      name: "General Manager",
      leadership_psu_pool_weighting: 1.0,
      notion_link: "https://notion.so/123"
    )

    # First period: January through March
    CollectiveRoleHolderPeriod.create!({
      collective_role: role,
      admin_user: leader,
      started_at: Date.new(2028, 1, 1),
      ended_at: Date.new(2028, 3, 31)
    })

    # Second period: July through September
    CollectiveRoleHolderPeriod.create!({
      collective_role: role,
      admin_user: leader,
      started_at: Date.new(2028, 7, 1),
      ended_at: Date.new(2028, 9, 30)
    })

    # Total days: 91 (Jan-Mar) + 92 (Jul-Sep) = 183 days
    expected_days = 91 + 92

    psu_distributions = profit_share_pass.psu_distributions
    distribution = psu_distributions.find { |p| p[:admin_user] == leader }
    expected_psu = (expected_days.to_f / (Date.new(2028).leap? ? 366 : 365)) * 70
    assert_equal distribution[:collective_leadership].round(2), expected_psu.round(2)
  end

  test "distributes project leadership PSU based on all days served when loosen flag is enabled" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2023, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    xxix, sanctu, g3d = make_g3d_studios!
    project_leader_1 = make_admin_user!(sanctu, Date.new(2020, 1, 1))

    # Unsuccessful project
    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    project_kickoff = profit_share_pass.created_at.beginning_of_year
    ProjectLeadPeriod.create!({
      project_tracker: project_tracker,
      admin_user: project_leader_1,
      studio: xxix,
      started_at: project_kickoff
    })
    ForecastAssignment.create!({
      forecast_id: 1,
      start_date: project_kickoff - 1.week,
      end_date: project_kickoff + 2.days,
      forecast_person: project_leader_1.forecast_person,
      forecast_project: forecast_project
    })
    assert_equal(false, project_tracker.considered_successful?)

    # Successful project
    project_leader_2 = make_admin_user!(sanctu, Date.new(2020, 1, 1), nil, "yoni@thoughtbot.com")
    forecast_project, forecast_client = make_forecast_project!
    project_tracker = make_project_tracker!([forecast_project])

    project_kickoff = profit_share_pass.created_at.beginning_of_year
    ProjectLeadPeriod.create!({
      project_tracker: project_tracker,
      admin_user: project_leader_2,
      studio: xxix,
      started_at: project_kickoff
    })
    ForecastAssignment.create!({
      forecast_id: 2,
      start_date: project_kickoff - 1.week,
      end_date: project_kickoff + 2.days,
      forecast_person: project_leader_2.forecast_person,
      forecast_project: forecast_project
    })
    # Setup successful project conditions
    project_tracker.generate_snapshot!
    project_tracker.update!(
      snapshot: project_tracker.snapshot.merge({
        "invoiced_with_running_spend_total" => project_tracker.snapshot["spend_total"]
      })
    )
    assert_equal(true, project_tracker.considered_successful?)

    assert_equal(0, profit_share_pass.awarded_project_leadership_psu_proportion_for_admin_user(project_leader_1))
    assert_equal(1, profit_share_pass.awarded_project_leadership_psu_proportion_for_admin_user(project_leader_2))

    profit_share_pass.stubs(:loosen_considered_successful_requirement_for_project_leadership_psu?).returns(true)

    assert_equal(0.5, profit_share_pass.awarded_project_leadership_psu_proportion_for_admin_user(project_leader_1))
    assert_equal(0.5, profit_share_pass.awarded_project_leadership_psu_proportion_for_admin_user(project_leader_2))
  end

  test "finalize! creates ProfitSharePayment records for each payment" do
    profit_share_pass = ProfitSharePass.create!({
      created_at: Date.new(2028, 1, 1),
      leadership_psu_pool_cap: 100,
      leadership_psu_pool_project_role_holders_percentage: 30
    })

    xxix, sanctu, g3d = make_g3d_studios!
    user1 = make_admin_user!(sanctu, Date.new(2020, 1, 1))
    user2 = make_admin_user!(sanctu, Date.new(2020, 1, 1), nil, "yoni@thoughtbot.com")

    # Set up some role holders to ensure we have payments to process
    role = CollectiveRole.create!(
      name: "General Manager",
      leadership_psu_pool_weighting: 1.0,
      notion_link: "https://notion.so/123"
    )

    CollectiveRoleHolderPeriod.create!({
      collective_role: role,
      admin_user: user1,
      started_at: Date.new(2028, 1, 1),
      ended_at: Date.new(2028, 12, 31)
    })

    profit_share_pass.stub(:pull_actuals_for_year, yearly_actuals) do
      # Get the payments that should be created
      expected_payments = profit_share_pass.payments

      assert_difference 'ProfitSharePayment.count', expected_payments.length do
        profit_share_pass.finalize!
      end

      # Verify each payment was created correctly
      expected_payments.each do |expected_payment|
        payment = ProfitSharePayment.find_by(
          profit_share_pass: profit_share_pass,
          admin_user: expected_payment[:admin_user]
        )

        assert payment.present?
        assert_equal expected_payment[:tenured_psu_earnt].round(2), payment.tenured_psu_earnt.round(2)
        assert_equal expected_payment[:project_leadership_psu_earnt].to_f.round(2), payment.project_leadership_psu_earnt.round(2)
        assert_equal expected_payment[:collective_leadership_psu_earnt].to_f.round(2), payment.collective_leadership_psu_earnt.round(2)
        assert_equal expected_payment[:pre_spent_profit_share].round(2), payment.pre_spent_profit_share.round(2)
        assert_equal expected_payment[:total_payout].round(2), payment.total_payout.round(2)
      end
    end
  end

  private

  def make_g3d_studios!
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
        "trailing_6_months": [{
          "cash": {
            "datapoints_excluding_reinvestment": {
              "cogs": { "value": 1_000_000 }
            }
          }
        }],
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

    [xxix, sanctu, g3d]
  end

  def yearly_actuals
    {
      gross_revenue: 6_000_000,
      gross_payroll: 2_500_000,
      gross_benefits: 350_000,
      gross_subcontractors: 1_800_000,
      gross_expenses: 400_000
    }
  end
end
