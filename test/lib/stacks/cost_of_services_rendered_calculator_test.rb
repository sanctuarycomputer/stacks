require "test_helper"

class Stacks::CostOfServicesRenderedCalculatorTest < ActiveSupport::TestCase
  test "#calculate returns the expected data for a two-person project" do
    start_date = Date.new(2024, 1, 1)
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
      forecast_id: 123,
      roles: [studio.name],
      email: user_one.email
    })

    person_two = ForecastPerson.create!({
      forecast_id: 456,
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

    assignment_one = ForecastAssignment.create!({
      forecast_id: 111,
      start_date: start_date,
      end_date: start_date + 4.days,
      forecast_person: person_one,
      forecast_project: forecast_project
    })

    assignment_two = ForecastAssignment.create!({
      forecast_id: 222,
      start_date: start_date,
      end_date: start_date + 4.days,
      forecast_person: person_two,
      forecast_project: forecast_project
    })

    assignment_three = ForecastAssignment.create!({
      forecast_id: 333,
      start_date: start_date + 1.week,
      end_date: start_date + 1.week + 2.days,
      forecast_person: person_one,
      forecast_project: forecast_project
    })

    assignment_four = ForecastAssignment.create!({
      forecast_id: 444,
      start_date: start_date + 1.week,
      end_date: start_date + 1.week + 2.days,
      forecast_person: person_two,
      forecast_project: forecast_project
    })

    current_date = start_date

    while current_date <= end_date
      first_week = current_date < start_date + 5.days

      ForecastAssignmentDailyFinancialSnapshot.create!({
        forecast_assignment: first_week ? assignment_one : assignment_three,
        forecast_person_id: person_one.id,
        forecast_project_id: forecast_project.id,
        effective_date: current_date,
        studio_id: studio.id,
        hourly_cost: first_week ? 33 : 44,
        hours: first_week ? 7 : 6,
        needs_review: false
      })

      ForecastAssignmentDailyFinancialSnapshot.create!({
        forecast_assignment: first_week ? assignment_two : assignment_four,
        forecast_person_id: person_two.id,
        forecast_project_id: forecast_project.id,
        effective_date: current_date,
        studio_id: studio.id,
        hourly_cost: first_week ? 44 : 55,
        hours: first_week ? 6 : 5,
        needs_review: false
      })

      current_date = current_date + 1.day
    end

    calculator = Stacks::CostOfServicesRenderedCalculator.new(
      start_date: start_date,
      end_date: end_date,
      forecast_project_ids: [forecast_project.id]
    )

    cosr = calculator.calculate

    assert_equal({
      start_date => {
        studio.id => {
          total_hours: 13,
          total_cost: 495,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_one.id,
              hours: 7,
              hourly_cost: 33,
              effective_date: start_date
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_two.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date
            }
          ]
        }
      },
      start_date + 1.day => {
        studio.id => {
          total_hours: 13,
          total_cost: 495,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_one.id,
              hours: 7,
              hourly_cost: 33,
              effective_date: start_date + 1.day
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_two.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date + 1.day
            }
          ]
        }
      },
      start_date + 2.days => {
        studio.id => {
          total_hours: 13,
          total_cost: 495,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_one.id,
              hours: 7,
              hourly_cost: 33,
              effective_date: start_date + 2.days
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_two.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date + 2.days
            }
          ]
        }
      },
      start_date + 3.days => {
        studio.id => {
          total_hours: 13,
          total_cost: 495,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_one.id,
              hours: 7,
              hourly_cost: 33,
              effective_date: start_date + 3.days
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_two.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date + 3.days
            }
          ]
        }
      },
      start_date + 4.days => {
        studio.id => {
          total_hours: 13,
          total_cost: 495,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_one.id,
              hours: 7,
              hourly_cost: 33,
              effective_date: start_date + 4.days
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_two.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date + 4.days
            }
          ]
        }
      },
      start_date + 5.days => {
        studio.id => {
          total_hours: 11,
          total_cost: 539,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_three.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date + 5.days
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_four.id,
              hours: 5,
              hourly_cost: 55,
              effective_date: start_date + 5.days
            }
          ]
        }
      },
      start_date + 6.days => {
        studio.id => {
          total_hours: 11,
          total_cost: 539,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_three.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date + 6.days
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_four.id,
              hours: 5,
              hourly_cost: 55,
              effective_date: start_date + 6.days
            }
          ]
        }
      },
      start_date + 7.days => {
        studio.id => {
          total_hours: 11,
          total_cost: 539,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_three.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date + 7.days
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_four.id,
              hours: 5,
              hourly_cost: 55,
              effective_date: start_date + 7.days
            }
          ]
        }
      },
      start_date + 8.days => {
        studio.id => {
          total_hours: 11,
          total_cost: 539,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_three.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date + 8.days
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_four.id,
              hours: 5,
              hourly_cost: 55,
              effective_date: start_date + 8.days
            }
          ]
        }
      },
      start_date + 9.days => {
        studio.id => {
          total_hours: 11,
          total_cost: 539,
          assignment_costs: [
            {
              forecast_person_id: person_one.id,
              forecast_assignment_id: assignment_three.id,
              hours: 6,
              hourly_cost: 44,
              effective_date: start_date + 9.days
            },
            {
              forecast_person_id: person_two.id,
              forecast_assignment_id: assignment_four.id,
              hours: 5,
              hourly_cost: 55,
              effective_date: start_date + 9.days
            }
          ]
        }
      }
    }, cosr)
  end
end
