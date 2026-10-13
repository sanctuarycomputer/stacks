require "test_helper"

class AdminCourseAuthoringTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = learning_person!(prefix: "boss", roles: ["admin"])
    @mod = learning_module!(steps: ["read"], questions: 1)
    @course = learning_course!(modules: [@mod])
    @qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
  end

  def lead!
    user = learning_person!(prefix: "lead")
    PermissionGrant.create!(admin_user: user, permission: "lead", granted_by: @admin)
    user
  end

  AUTHORING_PATHS = %i[admin_courses_path admin_learning_modules_path admin_qualifications_path admin_qualification_grants_path].freeze

  test "an admin can open every authoring index, new and edit page" do
    sign_in @admin
    AUTHORING_PATHS.each do |helper|
      get send(helper)
      assert_response :success, helper.to_s
    end
    [new_admin_course_path, edit_admin_course_path(@course), admin_course_path(@course),
     new_admin_learning_module_path, edit_admin_learning_module_path(@mod), admin_learning_module_path(@mod),
     new_admin_qualification_path, edit_admin_qualification_path(@qual),
     new_admin_qualification_grant_path].each do |path|
      get path
      assert_response :success, path
    end
  end

  test "a lead and an ordinary person can open none of them, and the answers never leak" do
    [lead!, learning_person!].each do |user|
      sign_in user
      get admin_admin_user_path(user)
      assert_response :success, "positive control: signed in"
      AUTHORING_PATHS.each do |helper|
        get send(helper)
        assert_not_equal 200, response.status, "#{user.email} reached #{helper}"
      end
      get admin_learning_module_path(@mod)
      assert_not_equal 200, response.status
      assert_not_includes response.body.to_s, "Because 0."
      get edit_admin_learning_module_path(@mod)
      assert_not_equal 200, response.status
      sign_out user
    end
  end

  test "an admin creates a module with a step and a question whose choices are typed one per line" do
    sign_in @admin
    post admin_learning_modules_path, params: { learning_module: {
      name: "How to send a weekly ship", slug: "weekly-ship", quiz_pass_percent: 80,
      module_steps_attributes: { "0" => { position: 0, kind: "auto_check", title: "Have a Forecast account", auto_check_key: "forecast_account" } },
      quiz_questions_attributes: { "0" => { position: 0, prompt: "When?", choices_text: "Friday\nMonday\n", correct_index: 0, explanation: "Fridays." } },
    } }
    mod = LearningModule.find_by!(slug: "weekly-ship")
    assert_equal ["auto_check", "forecast_account"], [mod.module_steps.first.kind, mod.module_steps.first.auto_check_key]
    assert_equal %w[Friday Monday], mod.quiz_questions.first.choices
  end

  test "an admin builds a course from existing modules in order" do
    other = learning_module!
    sign_in @admin
    post admin_courses_path, params: { course: {
      name: "Great Project Lead", slug: "great-pl", learner_title: "Becoming a Project Lead", grace_period_days: 30,
      qualification_id: @qual.id,
      course_modules_attributes: { "0" => { learning_module_id: other.id, position: 2 }, "1" => { learning_module_id: @mod.id, position: 1 } },
    } }
    course = Course.find_by!(slug: "great-pl")
    assert_equal [@mod, other], course.ordered_modules
    assert_equal @qual, course.qualification
  end

  test "an admin grants a qualification by hand; granted_by is stamped server-side" do
    person = learning_person!
    sign_in @admin
    post admin_qualification_grants_path, params: { qualification_grant: { admin_user_id: person.id, qualification_id: @qual.id, note: "pre-dates Stacks", granted_by_id: person.id } }
    grant = QualificationGrant.find_by!(admin_user: person, qualification: @qual)
    assert_equal @admin.id, grant.granted_by_id
    assert grant.granted_at.present?
  end

  test "a lead and an ordinary person cannot grant a qualification by POSTing" do
    target = learning_person!
    [lead!, learning_person!].each do |user|
      sign_in user
      post admin_qualification_grants_path, params: { qualification_grant: { admin_user_id: target.id, qualification_id: @qual.id } }
      sign_out user
    end
    assert_equal 0, QualificationGrant.count
  end

  test "an admin cannot grant themselves a qualification" do
    sign_in @admin
    post admin_qualification_grants_path, params: { qualification_grant: { admin_user_id: @admin.id, qualification_id: @qual.id } }
    assert_equal 0, QualificationGrant.where(admin_user: @admin).count
  end

  test "an impersonating admin cannot grant a qualification" do
    person = learning_person!
    sign_in @admin
    post impersonate_admin_admin_user_path(person)
    post admin_qualification_grants_path, params: { qualification_grant: { admin_user_id: person.id, qualification_id: @qual.id } }
    assert_equal 0, QualificationGrant.count
  end
end
