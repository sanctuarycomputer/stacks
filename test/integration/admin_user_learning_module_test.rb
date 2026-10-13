require "test_helper"

class AdminUserLearningModuleTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = learning_person!(prefix: "boss", roles: ["admin"])
    @person = learning_person!
    @mod = learning_module!(steps: ["read", "do"])
    @course = learning_course!(modules: [@mod])
  end

  test "nothing renders for a person with no assignment and no badge" do
    sign_in @person
    get admin_admin_user_path(@person)
    assert_response :success
    assert_not_includes response.body, "Getting on board"
    assert_not_includes response.body, "Badges"
    assert_not_includes response.body, ">Onboarding<"
  end

  test "the person sees their checklist with progress, due date and a link" do
    a = learning_assign!(@person, @course)
    complete_step!(@person, @mod.module_steps.first)
    sign_in @person
    get admin_admin_user_path(@person)
    assert_response :success
    assert_includes response.body, @course.learner_title
    assert_includes response.body, "1 of 2 steps done"
    assert_includes response.body, admin_course_assignment_path(a)
  end

  test "an admin sees it on someone else's profile" do
    learning_assign!(@person, @course)
    sign_in @admin
    get admin_admin_user_path(@person)
    assert_includes response.body, @course.learner_title
  end

  test "a lead does not see it on someone else's profile" do
    learning_assign!(@person, @course)
    badge = Qualification.create!(name: "Secret Badge #{SecureRandom.hex(3)}", kind: "badge")
    QualificationGrant.create!(admin_user: @person, qualification: badge, granted_at: Time.current)
    lead = learning_person!(prefix: "lead")
    PermissionGrant.create!(admin_user: lead, permission: "lead", granted_by: @admin)
    sign_in lead
    get admin_admin_user_path(@person)
    assert_response :success, "positive control: the lead can open the profile"
    assert_not_includes response.body, @course.learner_title
    assert_not_includes response.body, badge.name
  end

  test "badges show even with no assignment" do
    badge = Qualification.create!(name: "Hand Granted #{SecureRandom.hex(3)}", kind: "qualification")
    QualificationGrant.create!(admin_user: @person, qualification: badge, granted_at: Time.current)
    sign_in @person
    get admin_admin_user_path(@person)
    assert_includes response.body, "Badges"
    assert_includes response.body, badge.name
  end

  test "past due with only an admin sign-off left reads as waiting on an admin, not as overdue" do
    mod = learning_module!(steps: ["read", "admin_sign_off"])
    course = learning_course!(modules: [mod])
    learning_assign!(@person, course, due_on: Date.today - 2)
    complete_step!(@person, mod.module_steps.first)
    sign_in @person
    get admin_admin_user_path(@person)
    assert_includes response.body, "Waiting on an admin"
    assert_not_includes response.body, "Was due"
  end

  test "past due with the person's own work left still reads as was due" do
    learning_assign!(@person, @course, due_on: Date.today - 2)
    sign_in @person
    get admin_admin_user_path(@person)
    assert_includes response.body, "Was due"
    assert_not_includes response.body, "Waiting on an admin"
  end
end
