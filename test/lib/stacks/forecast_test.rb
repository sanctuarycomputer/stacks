require "test_helper"

class Stacks::ForecastTest < ActiveSupport::TestCase
  test "#sync_cost_windows! builds the expected cost windows for all projects" do
    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    old_project = ForecastProject.create!({
      id: 1,
      name: "Old project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      start_date: Date.today - 1.year
    })

    new_project = ForecastProject.create!({
      id: 2,
      name: "Current project",
      forecast_client: forecast_client,
      code: "ABCD-2",
      start_date: Date.today - 1.week
    })

    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    person_one = ForecastPerson.create!({
      forecast_id: "123",
      roles: [studio.name],
      email: user.email
    })

    person_two = ForecastPerson.create!({
      forecast_id: "456",
      roles: [studio.name, "Subcontractor"],
      email: "subcontractor@some-other-company.com"
    })

    FullTimePeriod.create!({
      admin_user: user,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: :five_day,
      expected_utilization: 0.8
    })

    ForecastAssignment.create!({
      forecast_id: "111",
      start_date: old_project.start_date,
      end_date: old_project.start_date + 20.days,
      forecast_person: person_one,
      forecast_project: old_project
    })

    ForecastAssignment.create!({
      forecast_id: "222",
      start_date: old_project.start_date,
      end_date: old_project.start_date + 10.days,
      forecast_person: person_two,
      forecast_project: old_project
    })

    ForecastAssignment.create!({
      forecast_id: "333",
      start_date: new_project.start_date,
      end_date: new_project.start_date + 20.days,
      forecast_person: person_one,
      forecast_project: new_project
    })

    ForecastAssignment.create!({
      forecast_id: "444",
      start_date: new_project.start_date,
      end_date: new_project.start_date + 10.days,
      forecast_person: person_two,
      forecast_project: new_project
    })

    Stacks::Forecast.new.sync_cost_windows!

    cost_window_attributes = ForecastPersonCostWindow.pluck(
      :forecast_person_id,
      :forecast_project_id,
      :start_date,
      :end_date,
      :hourly_cost,
      :needs_review
    )

    assert_equal([
      [123, 1, old_project.start_date, nil, 70.89, false],
      [456, 1, old_project.start_date, nil, 0, true],
      [123, 2, new_project.start_date, nil, 70.61, false],
      [456, 2, new_project.start_date, nil, 0, true]
    ], cost_window_attributes)
  end
end
