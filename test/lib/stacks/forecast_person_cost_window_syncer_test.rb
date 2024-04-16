require "test_helper"

class Stacks::ForecastPersonCostWindowSyncerTest < ActiveSupport::TestCase
  test "#sync! builds the expected cost windows when the person's compensation changes midway through a project" do
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
      start_date: start_date
    })

    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: "123",
      roles: [studio.name],
      email: user.email
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
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    ForecastPersonCostWindow.create!({
      forecast_person: forecast_person,
      forecast_project: forecast_project,
      start_date: start_date,
      end_date: nil,
      hourly_cost: 33,
      needs_review: false
    })

    syncer = Stacks::ForecastPersonCostWindowSyncer.new(
      forecast_project: forecast_project,
      forecast_person: forecast_person,
      target_date: end_date - 5.days
    )

    syncer.sync!

    cost_window_attributes = ForecastPersonCostWindow.where({
      forecast_person: forecast_person,
      forecast_project: forecast_project
    }).pluck(:start_date, :end_date, :hourly_cost, :needs_review)

    assert_equal([
      [start_date, start_date + 3.days, 33.00, false],
      [start_date + 4.days, nil, 70.61, false]
    ], cost_window_attributes)
  end

  test "#sync! builds the expected cost windows for a contractor using the notes specified on the Forecast project" do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.new(2024, 1, 10)

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      notes: "subcontractor-1@some-other-agency.com: $99.55\nsubcontractor-2@some-other-agency.com: $123.45",
      start_date: start_date
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: "123",
      roles: ["Subcontractor"],
      email: "subcontractor-2@some-other-agency.com"
    })

    ForecastAssignment.create!({
      forecast_id: "111",
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    syncer = Stacks::ForecastPersonCostWindowSyncer.new(
      forecast_project: forecast_project,
      forecast_person: forecast_person,
      target_date: start_date
    )

    syncer.sync!

    cost_window_attributes = ForecastPersonCostWindow.where({
      forecast_person: forecast_person,
      forecast_project: forecast_project
    }).pluck(:start_date, :end_date, :hourly_cost, :needs_review)

    assert_equal([
      [start_date, nil, 123.45, false],
    ], cost_window_attributes)
  end

  test "#sync! doesn't update cost windows if a matching cost window already exists" do
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
      start_date: start_date
    })

    user = AdminUser.create!({
      email: "josh@sanctuary.computer",
      password: "password"
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: "123",
      roles: [studio.name],
      email: user.email
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
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    ForecastPersonCostWindow.create!({
      forecast_person: forecast_person,
      forecast_project: forecast_project,
      start_date: start_date,
      end_date: nil,
      hourly_cost: 70.61,
      needs_review: false
    })

    syncer = Stacks::ForecastPersonCostWindowSyncer.new(
      forecast_project: forecast_project,
      forecast_person: forecast_person,
      target_date: end_date - 5.days
    )

    syncer.sync!

    cost_window_attributes = ForecastPersonCostWindow.where({
      forecast_person: forecast_person,
      forecast_project: forecast_project
    }).pluck(:start_date, :end_date, :hourly_cost, :needs_review)

    assert_equal([
      [start_date, nil, 70.61, false]
    ], cost_window_attributes)
  end

  test "#sync! flags new cost windows for review if their cost could not be determined" do
    start_date = Date.new(2024, 1, 1)
    end_date = Date.new(2024, 1, 10)

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
      # Notice: no cost overrides specified in notes field
      start_date: start_date
    })

    forecast_person = ForecastPerson.create!({
      forecast_id: "123",
      roles: ["Subcontractor"],
      email: "subcontractor@some-other-agency.com"
    })

    ForecastAssignment.create!({
      forecast_id: "111",
      start_date: start_date,
      end_date: end_date,
      forecast_person: forecast_person,
      forecast_project: forecast_project
    })

    syncer = Stacks::ForecastPersonCostWindowSyncer.new(
      forecast_project: forecast_project,
      forecast_person: forecast_person,
      target_date: start_date
    )

    syncer.sync!

    cost_window_attributes = ForecastPersonCostWindow.where({
      forecast_person: forecast_person,
      forecast_project: forecast_project
    }).pluck(:start_date, :end_date, :hourly_cost, :needs_review)

    assert_equal([
      [start_date, nil, 0, true],
    ], cost_window_attributes)
  end
end
