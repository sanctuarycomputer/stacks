require "test_helper"

# Guards the weekday checkbox UI on the Recurring Assignment admin form. Two coupled
# bugs it pins: (1) integer-valued collection so Formtastic marks the right box checked
# (string values never matched the record's integer weekdays -> everything rendered
# unchecked); (2) the model strips Formtastic's hidden "" placeholder so a submit does
# not land nil in the integer[] column and trip the 0..6 range validation.
class AdminRecurringAssignmentsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "admin-#{SecureRandom.hex(4)}@example.com",
      password: "password12345", password_confirmation: "password12345", roles: ["admin"]
    )
    sign_in @admin
  end

  test "edit form checks exactly the record's weekdays (Friday) and no others" do
    ra = RecurringAssignment.create!(
      forecast_person_id: 1, forecast_project_id: 2, allocation: 7200,
      weekdays: [5], starts_on: Date.today
    )
    get "/admin/recurring_assignments/#{ra.id}/edit"
    assert_response :success

    box = "input[type=checkbox][name='recurring_assignment[weekdays][]']"
    assert_select "#{box}[value='5'][checked]", 1, "Friday checkbox should be checked for weekdays [5]"
    assert_select "#{box}[value='1'][checked]", 0, "Monday checkbox should not be checked"
    assert_select "#{box}[value='0'][checked]", 0, "Sunday checkbox should not be checked"
  end

  test "submitting a checked weekday (with the hidden placeholder) saves without a range error" do
    ra = RecurringAssignment.create!(
      forecast_person_id: 1, forecast_project_id: 2, allocation: 7200,
      weekdays: [1, 2, 3, 4, 5], starts_on: Date.today
    )
    patch "/admin/recurring_assignments/#{ra.id}", params: {
      recurring_assignment: {
        forecast_person_id: 1, forecast_project_id: 2, allocation_in_hours: "0.5",
        weekdays: ["", "5"], starts_on: Date.today.to_s, notes: "",
      },
    }
    assert_redirected_to admin_recurring_assignment_path(ra)
    assert_equal [5], ra.reload.weekdays
  end
end
