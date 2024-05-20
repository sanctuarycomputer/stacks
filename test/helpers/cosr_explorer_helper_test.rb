require "test_helper"

class CosrExplorerHelperTest < ActiveSupport::TestCase
  include CosrExplorerHelper

  test "#build_monthly_rollup returns expected data for use in the template" do
    studio_id = 3

    monthly_studio_rollups, forecast_person_ids, studio_ids = build_monthly_rollup({
      Date.new(2024, 3, 13) => {
        studio_id => {
          total_hours: 4,
          total_cost: 311.16,
          assignment_costs: [
            {
              forecast_person_id: 79984011,
              forecast_assignment_id: 401479,
              hours: 4,
              hourly_cost: 77.79,
              effective_date: Date.new(2024, 3, 13)
            }
          ]
        }
      },
      Date.new(2024, 3, 14) => {
        studio_id => {
          total_hours: 3,
          total_cost: 226.19,
          assignment_costs: [
            {
              forecast_person_id: 79942931,
              forecast_assignment_id: 994567,
              hours: 1,
              hourly_cost: 70.61,
              effective_date: Date.new(2024, 3, 14)
            },
            {
              forecast_person_id: 79983971,
              forecast_assignment_id: 401479,
              hours: 2,
              hourly_cost: 77.79,
              effective_date: Date.new(2024, 3, 14)
            }
          ]
        }
      },
      Date.new(2024, 3, 15) => {
        studio_id => {
          total_hours: 3,
          total_cost: 233.37,
          assignment_costs: [
            {
              forecast_person_id: 79983787,
              forecast_assignment_id: 401479,
              hours: 3,
              hourly_cost: 77.79,
              effective_date: Date.new(2024, 3, 15)
            }
          ]
        }
      },
      Date.new(2024, 3, 16) => {},
      Date.new(2024, 3, 17) => {},
      Date.new(2024, 3, 18) => {},
      Date.new(2024, 3, 19) => {
        studio_id => {
          total_hours: 4,
          total_cost: 311.16,
          assignment_costs: [
            {
              forecast_person_id: 79983767,
              forecast_assignment_id: 401479,
              hours: 4,
              hourly_cost: 77.79,
              effective_date: Date.new(2024, 3, 19)
            }
          ]
        }
      }
    })

    assert_equal({
      Date.new(2024, 3, 1) => {
				studio_id => {
          total_cost: 1081.88,
          assignment_rollups: {
            "79984011-77.79" => {
              forecast_person_id: 79984011,
              hours: 4,
              hourly_cost: 77.79,
              total_cost: 311.16,
              start_date: Date.new(2024, 3, 13),
              end_date: Date.new(2024, 3, 13)
            },
            "79942931-70.61" => {
              forecast_person_id: 79942931,
              hours: 1,
              hourly_cost: 70.61,
              total_cost: 70.61,
              start_date: Date.new(2024, 3, 14),
              end_date: Date.new(2024, 3, 14)
            },
            "79983971-77.79" => {
              forecast_person_id: 79983971,
              hours: 2,
              hourly_cost: 77.79,
              total_cost: 155.58,
              start_date: Date.new(2024, 3, 14),
              end_date: Date.new(2024, 3, 14)
            },
            "79983787-77.79" => {
              forecast_person_id: 79983787,
              hours: 3,
              hourly_cost: 77.79,
              total_cost: 233.37,
              start_date: Date.new(2024, 3, 15),
              end_date: Date.new(2024, 3, 15)
            },
            "79983767-77.79" => {
              forecast_person_id: 79983767,
              hours: 4,
              hourly_cost: 77.79,
              total_cost: 311.16,
              start_date: Date.new(2024, 3, 19),
              end_date: Date.new(2024, 3, 19)
            }
          }
        }
      }
    }, monthly_studio_rollups)

    assert_equal([studio_id], studio_ids)

    assert_equal(
      [79984011, 79942931, 79983971, 79983787, 79983767],
      forecast_person_ids
    )
  end

  test "#format_date_range returns the expected string when the specified start and end dates are different" do
    formatted_date = format_date_range({
      start_date: Date.new(2024, 3, 1),
      end_date: Date.new(2024, 3, 15)
    })

    assert_equal(formatted_date, "3/1 to 3/15")
  end

  test "#format_date_range returns the expected string when the specified start and end dates are the same" do
    formatted_date = format_date_range({
      start_date: Date.new(2024, 3, 1),
      end_date: Date.new(2024, 3, 1)
    })

    assert_equal(formatted_date, "3/1")
  end
end
