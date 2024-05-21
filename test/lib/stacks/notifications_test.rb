require "test_helper"

class ProjectTrackertTest < ActiveSupport::TestCase
  test "#make_notifications! creates notifications for cost windows needing review" do
    Stacks::Quickbooks.stubs(:fetch_all_customers).returns([])
    Stacks::Team.stubs(:fetch_from_google_workspace).returns([])
    Stacks::Forecast.any_instance.stubs(:people).returns({
      "people" => []
    })

    Stacks::Notion.any_instance.stubs(:get_users).returns([])
    Stacks::Availability.stubs(:load_allocations_from_notion).returns([[], []])

    Stacks::Twist.any_instance.stubs(:get_workspace_users).returns(
      Struct.new(:parsed_response).new([])
    )

    studio = Studio.create!({
      name: "Sanctuary Computer",
      accounting_prefix: "Development",
      mini_name: "sc"
    })

    forecast_client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 55,
      name: "Test project",
      forecast_client: forecast_client,
      code: "ABCD-1",
    })

    person_one = ForecastPerson.create!({
      forecast_id: "123",
      roles: ["Subcontractor", studio.name],
      email: "subcontractor-1@some-other-company.com"
    })

    person_two = ForecastPerson.create!({
      forecast_id: "456",
      roles: ["Subcontractor", studio.name],
      email: "subcontractor-2@some-other-company.com"
    })

		assignment_one = ForecastAssignment.create!({
      forecast_id: 111,
      start_date: Date.today,
      end_date: Date.today + 5.days,
      forecast_person: person_one,
      forecast_project: forecast_project
    })

		assignment_two = ForecastAssignment.create!({
      forecast_id: 222,
      start_date: Date.today,
      end_date: Date.today + 5.days,
      forecast_person: person_two,
      forecast_project: forecast_project
    })

		ForecastAssignmentDailyFinancialSnapshot.create!({
      forecast_assignment: assignment_one,
      forecast_person_id: person_one.id,
      forecast_project_id: forecast_project.id,
      effective_date: Date.today,
      studio_id: studio.id,
      hourly_cost: 123,
      hours: 8,
      needs_review: false
    })

    ForecastAssignmentDailyFinancialSnapshot.create!({
      forecast_assignment: assignment_two,
      forecast_person_id: person_two.id,
      forecast_project_id: forecast_project.id,
      effective_date: Date.today,
      studio_id: studio.id,
      hourly_cost: 0,
      hours: 8,
      needs_review: true
    })

    Stacks::Notifications.make_notifications!

    notification = Notification.all.find do |notification|
      notification.params[:error] == :person_missing_hourly_rate
    end

    refute_nil(notification, "Expected notification not found")

    assert_equal(notification.params[:type], :forecast_project)
    assert_equal(notification.params[:subject].forecast_id, assignment_two.forecast_id)
    assert_equal(notification.params[:priority], 1)
    assert(notification.params[:link].end_with?("/projects/55/edit"))
  end
end

