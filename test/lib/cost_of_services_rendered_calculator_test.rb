require "test_helper"

class CostOfServicesRenderedCalculatorTest < ActiveSupport::TestCase
  test "#calculate returns the expected data for a two-person project with cost windows changing midway through" do
    start_date = Date.new(2024, 1, 1) # January 1st was a Monday.
    end_date = Date.new(2024, 1, 10)

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
    })

    user_one = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password",
    })

    user_two = AdminUser.create!({
      email: "antijosh@sanctuary.computer",
      password: "password",
    })

    person_one = ForecastPerson.create!({
      forecast_id: "123",
      roles: [studio.name],
      email: user_one.email
    })

    person_two = ForecastPerson.create!({
      forecast_id: "456",
      roles: [studio.name],
      email: user_two.email
    })

    FullTimePeriod.create!({
      admin_user: user_one,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: :five_day,
      expected_utilization: 0.8
    })

    FullTimePeriod.create!({
      admin_user: user_two,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: :five_day,
      expected_utilization: 0.8
    })

    ForecastAssignment.create!({
      forecast_id: "111",
      start_date: start_date,
      end_date: start_date + 4.days,
      forecast_person: person_one,
      forecast_project: forecast_project
    })

    ForecastAssignment.create!({
      forecast_id: "222",
      start_date: start_date,
      end_date: start_date + 4.days,
      forecast_person: person_two,
      forecast_project: forecast_project
    })

    ForecastAssignment.create!({
      forecast_id: "333",
      start_date: start_date + 1.week,
      end_date: start_date + 1.week + 2.days,
      forecast_person: person_one,
      forecast_project: forecast_project
    })

    ForecastAssignment.create!({
      forecast_id: "444",
      start_date: start_date + 1.week,
      end_date: start_date + 1.week + 2.days,
      forecast_person: person_two,
      forecast_project: forecast_project
    })

    ForecastPersonCostWindow.create!({
      forecast_person: person_one,
      started_at: start_date - 5.days,
      ended_at: end_date - 5.days,
      hourly_cost: 33
    })

    ForecastPersonCostWindow.create!({
      forecast_person: person_two,
      started_at: start_date - 5.days,
      ended_at: end_date - 5.days,
      hourly_cost: 44
    })

    ForecastPersonCostWindow.create!({
      forecast_person: person_one,
      started_at: start_date + 5.days,
      ended_at: end_date + 5.days,
      hourly_cost: 55
    })

    ForecastPersonCostWindow.create!({
      forecast_person: person_two,
      started_at: start_date + 5.days,
      ended_at: end_date + 5.days,
      hourly_cost: 66
    })

    all_assignments = [
      *person_one.forecast_assignments,
      *person_two.forecast_assignments
    ]

    calculator = Stacks::CostOfServicesRenderedCalculator.new(
      start_date: start_date,
      end_date: end_date,
      assignments: all_assignments,
      cost_windows: ForecastPersonCostWindow.all,
      studios: Studio.all
    )

    cosr = calculator.calculate

    assert_equal({
      start_date => {
        studio.id => {
          total_hours: 16,
          total_cost: 616,
          assignment_costs: [
            {
              forecast_assignment_id: 111,
              hourly_cost: 33,
              hours: 8
            },
            {
              forecast_assignment_id: 222,
              hourly_cost: 44,
              hours: 8
            }
          ]
        }
      },
      start_date + 1.day => {
        studio.id => {
          total_hours: 16,
          total_cost: 616,
          assignment_costs: [
            {
              forecast_assignment_id: 111,
              hourly_cost: 33,
              hours: 8
            },
            {
              forecast_assignment_id: 222,
              hourly_cost: 44,
              hours: 8
            }
          ]
        }
      },
      start_date + 2.days => {
        studio.id => {
          total_hours: 16,
          total_cost: 616,
          assignment_costs: [
            {
              forecast_assignment_id: 111,
              hourly_cost: 33,
              hours: 8
            },
            {
              forecast_assignment_id: 222,
              hourly_cost: 44,
              hours: 8
            }
          ]
        }
      },
      start_date + 3.days => {
        studio.id => {
          total_hours: 16,
          total_cost: 616,
          assignment_costs: [
            {
              forecast_assignment_id: 111,
              hourly_cost: 33,
              hours: 8
            },
            {
              forecast_assignment_id: 222,
              hourly_cost: 44,
              hours: 8
            }
          ]
        }
      },
      start_date + 4.days => {
        studio.id => {
          total_hours: 16,
          total_cost: 616,
          assignment_costs: [
            {
              forecast_assignment_id: 111,
              hourly_cost: 33,
              hours: 8
            },
            {
              forecast_assignment_id: 222,
              hourly_cost: 44,
              hours: 8
            }
          ]
        }
      },
      start_date + 7.days => {
        studio.id => {
          total_hours: 16,
          total_cost: 968,
          assignment_costs: [
            {
              forecast_assignment_id: 333,
              hourly_cost: 55,
              hours: 8
            },
            {
              forecast_assignment_id: 444,
              hourly_cost: 66,
              hours: 8
            }
          ]
        }
      },
      start_date + 8.days => {
        studio.id => {
          total_hours: 16,
          total_cost: 968,
          assignment_costs: [
            {
              forecast_assignment_id: 333,
              hourly_cost: 55,
              hours: 8
            },
            {
              forecast_assignment_id: 444,
              hourly_cost: 66,
              hours: 8
            }
          ]
        }
      },
      start_date + 9.days => {
        studio.id => {
          total_hours: 16,
          total_cost: 968,
          assignment_costs: [
            {
              forecast_assignment_id: 333,
              hourly_cost: 55,
              hours: 8
            },
            {
              forecast_assignment_id: 444,
              hourly_cost: 66,
              hours: 8
            }
          ]
        }
      }
    }, cosr)
  end
end
