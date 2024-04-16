require "test_helper"

class ProjectTrackertTest < ActiveSupport::TestCase
  test "#generate_snapshot! records the expected snapshot data" do
    start_date = Date.new(2024, 1, 1) # January 1st was a Monday.
    end_date = Date.new(2024, 1, 10)

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc",
      snapshot: {
        "month" => [
          {
            "label" => "January, 2024",
            "cash" => {
              "datapoints" => {
                "cost_per_sellable_hour" => {
                  "value" => 123
                },
                "actual_cost_per_hour_sold" => {
                  "value" => 100
                }
              }
            },
            "accrual" => {
              "datapoints" => {
                "cost_per_sellable_hour" => {
                  "value" => 111
                },
                "actual_cost_per_hour_sold" => {
                  "value" => 90
                }
              }
            }
          }
        ]
      }
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
      forecast_project: forecast_project,
      start_date: start_date - 5.days,
      end_date: end_date - 5.days,
      hourly_cost: 33,
      needs_review: false
    })

    ForecastPersonCostWindow.create!({
      forecast_person: person_two,
      forecast_project: forecast_project,
      start_date: start_date - 5.days,
      end_date: end_date - 5.days,
      hourly_cost: 44,
      needs_review: false
    })

    ForecastPersonCostWindow.create!({
      forecast_person: person_one,
      forecast_project: forecast_project,
      start_date: start_date + 5.days,
      end_date: end_date + 5.days,
      hourly_cost: 55,
      needs_review: false
    })

    ForecastPersonCostWindow.create!({
      forecast_person: person_two,
      forecast_project: forecast_project,
      start_date: start_date + 5.days,
      end_date: end_date + 5.days,
      hourly_cost: 66,
      needs_review: false
    })

    project_tracker_links = [
      ProjectTrackerLink.new({
        name: "SOW link",
        url: "https://example.com",
        link_type: "sow"
      }),
      ProjectTrackerLink.new({
        name: "MSA link",
        url: "https://example.com",
        link_type: "msa"
      })
    ]

    tracker = ProjectTracker.create!({
      name: "Test project 1",
      forecast_projects: [forecast_project],
      project_tracker_links: project_tracker_links
    })

    tracker.generate_snapshot!
    current_timestamp = DateTime.now.iso8601

    assert_equal({
      "generated_at" => current_timestamp,
      "hours" => [
        {"x" => "2024-01-01", "y" => 16.0},
        {"x" => "2024-01-02", "y" => 32.0},
        {"x" => "2024-01-03", "y" => 48.0},
        {"x" => "2024-01-04", "y" => 64.0},
        {"x" => "2024-01-05", "y" => 80.0},
        {"x" => "2024-01-06", "y" => 80.0},
        {"x" => "2024-01-07", "y" => 80.0},
        {"x" => "2024-01-08", "y" => 96.0},
        {"x" => "2024-01-09", "y" => 112.0},
        {"x" => "2024-01-10", "y" => 128.0}
      ],
      "hours_new" => [
        {"x" => "2024-01-01", "y" => 16.0},
        {"x" => "2024-01-02", "y" => 32.0},
        {"x" => "2024-01-03", "y" => 48.0},
        {"x" => "2024-01-04", "y" => 64.0},
        {"x" => "2024-01-05", "y" => 80.0},
        {"x" => "2024-01-06", "y" => 80.0},
        {"x" => "2024-01-07", "y" => 80.0},
        {"x" => "2024-01-08", "y" => 96.0},
        {"x" => "2024-01-09", "y" => 112.0},
        {"x" => "2024-01-10", "y" => 128.0}
      ],
      "spend" => [
        {"x" => "2024-01-01", "y" => 2800.0},
        {"x" => "2024-01-02", "y" => 5600.0},
        {"x" => "2024-01-03", "y" => 8400.0},
        {"x" => "2024-01-04", "y" => 11200.0},
        {"x" => "2024-01-05", "y" => 14000.0},
        {"x" => "2024-01-06", "y" => 14000.0},
        {"x" => "2024-01-07", "y" => 14000.0},
        {"x" => "2024-01-08", "y" => 16800.0},
        {"x" => "2024-01-09", "y" => 19600.0},
        {"x" => "2024-01-10", "y" => 22400.0}
      ],
      "hours_total" => 128.0,
      "hours_total_new" => 128.0,
      "spend_total" => 22400.0,
      "cash" => {
        "cosr" => [
          {"x" => "2024-01-01", "y" => 1600.0},
          {"x" => "2024-01-02", "y" => 3200.0},
          {"x" => "2024-01-03", "y" => 4800.0},
          {"x" => "2024-01-04", "y" => 6400.0},
          {"x" => "2024-01-05", "y" => 8000.0},
          {"x" => "2024-01-06", "y" => 8000.0},
          {"x" => "2024-01-07", "y" => 8000.0},
          {"x" => "2024-01-08", "y" => 9600.0},
          {"x" => "2024-01-09", "y" => 11200.0},
          {"x" => "2024-01-10", "y" => 12800.0}
        ],
        "cosr_new" => [
          {"x" => "2024-01-01", "y" => 616.0},
          {"x" => "2024-01-02", "y" => 1232.0},
          {"x" => "2024-01-03", "y" => 1848.0},
          {"x" => "2024-01-04", "y" => 2464.0},
          {"x" => "2024-01-05", "y" => 3080.0},
          {"x" => "2024-01-06", "y" => 3080.0},
          {"x" => "2024-01-07", "y" => 3080.0},
          {"x" => "2024-01-08", "y" => 4048.0},
          {"x" => "2024-01-09", "y" => 5016.0},
          {"x" => "2024-01-10", "y" => 5984.0}
        ],
        "cosr_total" => 12800.0,
        "cosr_total_new" => 5984.0
      },
      "accrual" =>{
        "cosr" => [
          {"x" => "2024-01-01", "y" => 1440.0},
          {"x" => "2024-01-02", "y" => 2880.0},
          {"x" => "2024-01-03", "y" => 4320.0},
          {"x" => "2024-01-04", "y" => 5760.0},
          {"x" => "2024-01-05", "y" => 7200.0},
          {"x" => "2024-01-06", "y" => 7200.0},
          {"x" => "2024-01-07", "y" => 7200.0},
          {"x" => "2024-01-08", "y" => 8640.0},
          {"x" => "2024-01-09", "y" => 10080.0},
          {"x" => "2024-01-10", "y" => 11520.0}
        ],
        "cosr_new" => [
          {"x" => "2024-01-01", "y" => 616.0},
          {"x" => "2024-01-02", "y" => 1232.0},
          {"x" => "2024-01-03", "y" => 1848.0},
          {"x" => "2024-01-04", "y" => 2464.0},
          {"x" => "2024-01-05", "y" => 3080.0},
          {"x" => "2024-01-06", "y" => 3080.0},
          {"x" => "2024-01-07", "y" => 3080.0},
          {"x" => "2024-01-08", "y" => 4048.0},
          {"x" => "2024-01-09", "y" => 5016.0},
          {"x" => "2024-01-10", "y" => 5984.0}
        ],
        "cosr_total" => 11520.0,
        "cosr_total_new" => 5984.0
      }
    }, tracker.snapshot.merge({
      "generated_at" => current_timestamp
    }))
  end
end
