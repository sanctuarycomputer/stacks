require "test_helper"

class AdminUserCourseAutoAssignTest < ActiveSupport::TestCase
  setup do
    @auto = learning_course!(modules: [learning_module!], auto_assign: true)
    @manual = learning_course!(modules: [learning_module!], auto_assign: false)
  end

  test "a new company-email person is assigned auto-assign courses only" do
    person = learning_person!
    assert_equal [@auto.id], person.course_assignments.pluck(:course_id)
    a = person.course_assignments.first
    assert_nil a.assigned_by_id
    assert_equal Date.today, a.assigned_on
    assert_equal Date.today + @auto.grace_period_days, a.due_on
  end

  test "the discovery path assigns too" do
    email = "found#{SecureRandom.hex(4)}@xxix.co"
    person = AdminUser.find_or_create_by_g3d_uid!(email)
    assert_equal [@auto.id], person.course_assignments.pluck(:course_id)
    assert_no_difference -> { CourseAssignment.count } do
      AdminUser.find_or_create_by_g3d_uid!(email)
    end
  end

  test "a non-company email is not assigned anything" do
    outsider = AdminUser.create!(email: "x#{SecureRandom.hex(4)}@example.com",
                                 password: "password12345", password_confirmation: "password12345")
    assert_equal 0, outsider.course_assignments.count
  end

  test "people who already exist are not assigned when a course is switched on" do
    existing = learning_person!
    existing.course_assignments.delete_all
    @manual.update!(auto_assign: true)
    assert_equal 0, existing.reload.course_assignments.count
  end

  test "a database error while assigning leaves the account persisted" do
    CourseAssignment.stubs(:create!).raises(ActiveRecord::StatementInvalid, "PG::Error: boom")
    person = nil
    assert_nothing_raised { person = learning_person! }
    assert AdminUser.exists?(person.id)
    assert_equal 0, person.course_assignments.count
  end

  test "calling it twice does not duplicate" do
    person = learning_person!
    assert_no_difference(-> { CourseAssignment.count }) { person.assign_auto_assigned_courses! }
  end
end
