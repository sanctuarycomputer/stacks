require "test_helper"

class ProjectTrackerTest < ActiveSupport::TestCase
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
      contributor_type: Enum::ContributorType::FIVE_DAY,
      expected_utilization: 0.8
    })

    FullTimePeriod.create!({
      admin_user: user_two,
      started_at: Date.new(2020, 1, 1),
      ended_at: nil,
      contributor_type: Enum::ContributorType::FIVE_DAY,
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
      if current_date.saturday? || current_date.sunday?
        current_date = current_date + 1.day
        next
      end

      ForecastAssignmentDailyFinancialSnapshot.create!({
        forecast_assignment: (
          assignment_one.end_date >= current_date ?
          assignment_one :
          assignment_three
        ),
        forecast_person_id: person_one.id,
        forecast_project_id: forecast_project.id,
        effective_date: current_date,
        studio_id: studio.id,
        hourly_cost: 55,
        hours: 6,
        needs_review: false
      })

      ForecastAssignmentDailyFinancialSnapshot.create!({
        forecast_assignment: (
          assignment_two.end_date >= current_date ?
          assignment_two :
          assignment_four
        ),
        forecast_person_id: person_two.id,
        forecast_project_id: forecast_project.id,
        effective_date: current_date,
        studio_id: studio.id,
        hourly_cost: 44,
        hours: 7,
        needs_review: false
      })

      current_date = current_date + 1.day
    end

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

    expected = {
      "generated_at"=> current_timestamp,
      "hours"=> [
        {"x" => "2024-01-01", "y" => 13},
        {"x" => "2024-01-02", "y" => 26},
        {"x" => "2024-01-03", "y" => 39},
        {"x" => "2024-01-04", "y" => 52},
        {"x" => "2024-01-05", "y" => 65},
        {"x" => "2024-01-06", "y" => 65},
        {"x" => "2024-01-07", "y" => 65},
        {"x" => "2024-01-08", "y" => 78},
        {"x" => "2024-01-09", "y" => 91},
        {"x" => "2024-01-10", "y" => 104}
      ],
      "spend"=> [
        {"x" => "2024-01-01", "y" => 2800},
        {"x" => "2024-01-02", "y" => 5600},
        {"x" => "2024-01-03", "y" => 8400},
        {"x" => "2024-01-04", "y" => 11200},
        {"x" => "2024-01-05", "y" => 14000},
        {"x" => "2024-01-06", "y" => 14000},
        {"x" => "2024-01-07", "y" => 14000},
        {"x" => "2024-01-08", "y" => 16800},
        {"x" => "2024-01-09", "y" => 19600},
        {"x" => "2024-01-10", "y" => 22400}
      ],
      "hours_total" => 104,
      "hours_free" => 0,
      "spend_total" => 22400.0,
      "invoiced_income_total"=>0.0,
      "invoiced_with_running_spend_total"=>0.0,
      "cash"=> {
        "cosr"=> [
          {"x" => "2024-01-01", "y" => 638},
          {"x" => "2024-01-02", "y" => 1276},
          {"x" => "2024-01-03", "y" => 1914},
          {"x" => "2024-01-04", "y" => 2552},
          {"x" => "2024-01-05", "y" => 3190},
          {"x" => "2024-01-06", "y" => 3190},
          {"x" => "2024-01-07", "y" => 3190},
          {"x" => "2024-01-08", "y" => 3828},
          {"x" => "2024-01-09", "y" => 4466},
          {"x" => "2024-01-10", "y" => 5104}
        ],
        "cosr_total" => 5104
      },
      "accrual"=> {
        "cosr"=> [
          {"x" => "2024-01-01", "y" => 638},
          {"x" => "2024-01-02", "y" => 1276},
          {"x" => "2024-01-03", "y" => 1914},
          {"x" => "2024-01-04", "y" => 2552},
          {"x" => "2024-01-05", "y" => 3190},
          {"x" => "2024-01-06", "y" => 3190},
          {"x" => "2024-01-07", "y" => 3190},
          {"x" => "2024-01-08", "y" => 3828},
          {"x" => "2024-01-09", "y" => 4466},
          {"x" => "2024-01-10", "y" => 5104}
        ],
        # ($44 * 7hrs * 8days) + ($55 * 6hrs * 8days) = $5104
        "cosr_total" => 5104
      }
    }

    actual = tracker.snapshot.merge({
      "generated_at" => current_timestamp
    })

    assert_equal(expected, actual)
  end
end
