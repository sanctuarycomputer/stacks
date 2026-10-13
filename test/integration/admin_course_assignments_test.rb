# test/integration/admin_course_assignments_test.rb
require "test_helper"

class AdminCourseAssignmentsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = learning_person!(prefix: "boss", roles: ["admin"])
    @person = learning_person!
    @other = learning_person!(prefix: "other")
    @mod = learning_module!(steps: ["read", ["auto_check", "forecast_account"], "admin_sign_off"], questions: 2, pass_percent: 100)
    @course = learning_course!(modules: [@mod])
    @assignment = learning_assign!(@person, @course)
    @read, @auto, @sign_off = @mod.module_steps.to_a
  end

  def lead!
    user = learning_person!(prefix: "lead")
    PermissionGrant.create!(admin_user: user, permission: "lead", granted_by: @admin)
    user
  end

  def done?(person, step)
    StepCompletion.exists?(admin_user: person, module_step: step)
  end

  def all_right
    @mod.quiz_questions.to_h { |q| [q.id.to_s, q.correct_index.to_s] }
  end

  def all_wrong
    @mod.quiz_questions.to_h { |q| [q.id.to_s, ((q.correct_index + 1) % q.choices.size).to_s] }
  end

  # ── the person ────────────────────────────────────────────────────────────

  test "a person sees their own checklist in getting-set-up language" do
    sign_in @person
    get admin_course_assignment_path(@assignment)
    assert_response :success
    assert_includes response.body, @course.learner_title
    assert_includes response.body, @read.title
    assert_includes response.body, "Quick check"
    %w[quiz Quiz lesson training learner].each do |word|
      assert_not_includes response.body.gsub(/href="[^"]*"|action="[^"]*"/, ""), word, "person-facing page says #{word.inspect}"
    end
  end

  test "a person ticks a read step" do
    sign_in @person
    post complete_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
    completion = StepCompletion.find_by!(admin_user: @person, module_step: @read)
    assert_equal "self", completion.source
    assert_nil completion.completed_by_id
  end

  test "a person cannot tick an auto_check or admin_sign_off step" do
    sign_in @person
    post complete_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert done?(@person, @read), "positive control: the same request shape works for a read step"

    post complete_step_admin_course_assignment_path(@assignment, step_id: @auto.id)
    post complete_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @auto)
    assert_not done?(@person, @sign_off)
  end

  test "a person cannot tick a step from a module outside their course" do
    stray = learning_module!(steps: ["read"]).module_steps.first
    sign_in @person
    post complete_step_admin_course_assignment_path(@assignment, step_id: stray.id)
    assert_not done?(@person, stray)
  end

  test "a person cannot see or act on someone else's checklist" do
    theirs = learning_assign!(@other, @course)
    sign_in @person
    get admin_course_assignment_path(@assignment)
    assert_response :success, "positive control: the session is live"

    get admin_course_assignment_path(theirs)
    assert_not_equal 200, response.status
    assert_not_includes response.body.to_s, @read.title
    assert_no_difference "StepCompletion.count" do
      post complete_step_admin_course_assignment_path(theirs, step_id: @read.id)
    end
    [@read, @auto, @sign_off].each { |s| complete_step!(@other, s) }
    get quiz_admin_course_assignment_path(theirs, learning_module_id: @mod.id)
    assert_not_equal 200, response.status
    post submit_quiz_admin_course_assignment_path(theirs, learning_module_id: @mod.id), params: { answers: all_right }
    assert_equal 0, QuizAttempt.count

    sign_out @person
    sign_in @other
    get quiz_admin_course_assignment_path(theirs, learning_module_id: @mod.id)
    assert_response :success, "positive control: the quick check really is open for its owner"
  end

  test "a person gets no index" do
    sign_in @person
    get admin_course_assignments_path
    assert_not_equal 200, response.status
  end

  test "a person cannot sign off, mark done for or waive, even on their own" do
    complete_step!(@person, @read)
    complete_step!(@person, @auto, source: "auto")
    sign_in @person
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off), "the sign-off was ready"
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    other_mod = learning_module!(steps: ["do"])
    @course.course_modules.create!(learning_module: other_mod, position: 5)
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: other_mod.module_steps.first.id)
    assert_not done?(@person, other_mod.module_steps.first)
    post waive_admin_course_assignment_path(@assignment), params: { waive_note: "nope" }
    assert_nil @assignment.reload.waived_at
  end

  test "a person cannot grant themselves a retry when locked out" do
    [@read, @auto, @sign_off].each { |s| complete_step!(@person, s) }
    2.times { QuizAttempt.create!(admin_user: @person, learning_module: @mod, correct_count: 0, question_count: 2) }
    sign_in @person
    post grant_quiz_retry_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_equal 0, QuizRetryGrant.count
  end

  # ── the quick check ───────────────────────────────────────────────────────

  def finish_steps!
    [@read, @auto, @sign_off].each { |s| complete_step!(@person, s) }
  end

  test "the quick check is closed until the steps are done" do
    sign_in @person
    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_right }
    assert_equal 0, QuizAttempt.count
  end

  test "the quick check page shows questions and choices but never answers or explanations" do
    finish_steps!
    sign_in @person
    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_response :success
    assert_includes response.body, "Question 0?"
    assert_includes response.body, "wrong1"
    assert_not_includes response.body, "Because 0."
    assert_not_includes response.body, "correct_index"
  end

  test "failing shows the score only, then locks after the second attempt" do
    finish_steps!
    sign_in @person
    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_wrong }
    assert_redirected_to admin_course_assignment_path(@assignment)
    follow_redirect!
    assert_includes response.body, "0 of 2"
    assert_not_includes response.body, "Because 0."

    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_wrong }
    follow_redirect!
    assert_includes response.body, "out of attempts"

    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_right }
    assert_equal 2, QuizAttempt.where(admin_user: @person).count
    assert_nil @assignment.reload.completed_at

    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
  end

  test "passing completes the checklist, and only then are explanations shown" do
    finish_steps!
    sign_in @person
    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_right }
    assert @assignment.reload.completed_at.present?

    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_response :success
    assert_includes response.body, "Because 0."
  end

  # ── admins ────────────────────────────────────────────────────────────────

  test "an admin sees anyone's checklist and the index" do
    sign_in @admin
    get admin_course_assignment_path(@assignment)
    assert_response :success
    assert_includes response.body, "Mark done for them"
    assert_not_includes response.body, "Sign off", "the sign-off is not ready yet"
    get admin_course_assignments_path
    assert_response :success
    assert_includes response.body, @person.email
  end

  test "an admin signs off a ready step, stamped with who did it" do
    complete_step!(@person, @read)
    complete_step!(@person, @auto, source: "auto")
    sign_in @admin
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    completion = StepCompletion.find_by!(admin_user: @person, module_step: @sign_off)
    assert_equal ["admin", @admin.id], [completion.source, completion.completed_by_id]
  end

  test "an admin cannot sign off a step that is not ready, or a step that is not a sign-off" do
    sign_in @admin
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off), "earlier steps are not done"
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert_not done?(@person, @read)
  end

  test "an admin marks a step done for someone, but not a sign-off through that route" do
    sign_in @admin
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: @auto.id)
    completion = StepCompletion.find_by!(admin_user: @person, module_step: @auto)
    assert_equal ["admin", @admin.id], [completion.source, completion.completed_by_id]
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off)
  end

  test "an admin grants a retry only once the person is locked out, and waives" do
    sign_in @admin
    post grant_quiz_retry_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_equal 0, QuizRetryGrant.count, "not locked yet"
    [@read, @auto, @sign_off].each { |s| complete_step!(@person, s) }
    2.times { QuizAttempt.create!(admin_user: @person, learning_module: @mod, correct_count: 0, question_count: 2) }
    post grant_quiz_retry_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { note: "was ill" }
    grant = QuizRetryGrant.find_by!(admin_user: @person, learning_module: @mod)
    assert_equal [@admin.id, "was ill"], [grant.granted_by_id, grant.note]

    post waive_admin_course_assignment_path(@assignment), params: { waive_note: "joined years ago" }
    @assignment.reload
    assert @assignment.waived_at.present?
    assert_equal [@admin.id, "joined years ago"], [@assignment.waived_by_id, @assignment.waive_note]
  end

  test "an admin can do none of the admin actions on their own checklist" do
    mine = learning_assign!(@admin, @course)
    sign_in @admin
    post complete_step_admin_course_assignment_path(mine, step_id: @read.id)
    assert done?(@admin, @read), "positive control: they can still tick their own read step"

    post complete_step_for_admin_course_assignment_path(mine, step_id: @auto.id)
    assert_not done?(@admin, @auto)
    complete_step!(@admin, @auto, source: "auto")
    post sign_off_step_admin_course_assignment_path(mine, step_id: @sign_off.id)
    assert_not done?(@admin, @sign_off)
    complete_step!(@admin, @sign_off)
    2.times { QuizAttempt.create!(admin_user: @admin, learning_module: @mod, correct_count: 0, question_count: 2) }
    post grant_quiz_retry_admin_course_assignment_path(mine, learning_module_id: @mod.id)
    assert_equal 0, QuizRetryGrant.count
    post waive_admin_course_assignment_path(mine)
    assert_nil mine.reload.waived_at
  end

  test "nothing can be signed off or marked done on a waived checklist" do
    @assignment.update!(waived_at: Time.current)
    sign_in @admin
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: @auto.id)
    assert_not done?(@person, @auto)
  end

  test "check again runs the automatic checks, and malformed ids do not 500" do
    ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: @person.email, data: {})
    sign_in @person
    post recheck_admin_course_assignment_path(@assignment)
    assert_redirected_to admin_course_assignment_path(@assignment)
    assert_equal "auto", StepCompletion.find_by!(admin_user: @person, module_step: @auto).source

    post complete_step_admin_course_assignment_path(@assignment), params: { step_id: { x: 1 } }
    assert_response :redirect
    [@read, @sign_off].each { |s| complete_step!(@person, s) unless done?(@person, s) }
    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: ["1"] }
    assert_response :redirect
    assert_equal 0, QuizAttempt.count
  end

  test "an admin cannot delete an assignment" do
    sign_in @admin
    assert_raises(ActionController::RoutingError, NoMethodError) do
      delete "/admin/course_assignments/#{@assignment.id}"
    end
    assert CourseAssignment.exists?(@assignment.id)
  end

  test "an admin assigns by hand; assigned_by is stamped server-side and only due_on is editable" do
    sign_in @admin
    course = learning_course!(modules: [learning_module!])
    post admin_course_assignments_path, params: { course_assignment: { admin_user_id: @other.id, course_id: course.id, assigned_by_id: @person.id } }
    created = CourseAssignment.find_by!(admin_user: @other, course: course)
    assert_equal @admin.id, created.assigned_by_id

    patch admin_course_assignment_path(created), params: { course_assignment: { due_on: (Date.today + 30).to_s, admin_user_id: @person.id, completed_at: Time.current.to_s } }
    created.reload
    assert_equal Date.today + 30, created.due_on
    assert_equal @other.id, created.admin_user_id
    assert_nil created.completed_at
  end

  # ── impersonation ─────────────────────────────────────────────────────────

  test "while impersonating, the admin sees the person's view and every POST is refused" do
    finish = -> { [@read, @auto].each { |s| complete_step!(@person, s) } }
    sign_in @admin
    post impersonate_admin_admin_user_path(@person)
    get admin_course_assignment_path(@assignment)
    assert_response :success

    post complete_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert_not done?(@person, @read)
    ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: @person.email, data: {})
    post recheck_admin_course_assignment_path(@assignment)
    assert_equal 0, StepCompletion.where(admin_user: @person).count, "a real recheck would have completed the auto step"
    finish.call
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off)
    complete_step!(@person, @sign_off, source: "admin")
    post submit_quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id), params: { answers: all_right }
    assert_equal 0, QuizAttempt.count
    post waive_admin_course_assignment_path(@assignment)
    assert_nil @assignment.reload.waived_at
    2.times { QuizAttempt.create!(admin_user: @person, learning_module: @mod, correct_count: 0, question_count: 2) }
    post grant_quiz_retry_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_equal 0, QuizRetryGrant.count
  end

  test "an admin impersonating another admin still cannot act on a checklist" do
    second = learning_person!(prefix: "second", roles: ["admin"])
    sign_in @admin
    post impersonate_admin_admin_user_path(second)
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: @auto.id)
    assert_not done?(@person, @auto)
    post waive_admin_course_assignment_path(@assignment)
    assert_nil @assignment.reload.waived_at

    complete_step!(@person, @read)
    complete_step!(@person, @auto, source: "auto")
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off)
    complete_step!(@person, @sign_off)
    2.times { QuizAttempt.create!(admin_user: @person, learning_module: @mod, correct_count: 0, question_count: 2) }
    post grant_quiz_retry_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_equal 0, QuizRetryGrant.count
  end

  test "an admin impersonating another admin cannot reach the assignment REST actions" do
    second = learning_person!(prefix: "second", roles: ["admin"])
    sign_in @admin
    post impersonate_admin_admin_user_path(second)
    course = learning_course!(modules: [learning_module!])
    assert_no_difference "CourseAssignment.count" do
      post admin_course_assignments_path, params: { course_assignment: { admin_user_id: @other.id, course_id: course.id } }
    end
    original = @assignment.due_on
    patch admin_course_assignment_path(@assignment), params: { course_assignment: { due_on: (Date.today + 90).to_s } }
    assert_equal original, @assignment.reload.due_on
    get new_admin_course_assignment_path
    assert_redirected_to admin_course_assignments_path
    get edit_admin_course_assignment_path(@assignment)
    assert_redirected_to admin_course_assignments_path
  end

  test "an admin cannot change the due date on their own assignment, but can on someone else's" do
    mine = learning_assign!(@admin, @course)
    original = mine.due_on
    sign_in @admin
    patch admin_course_assignment_path(mine), params: { course_assignment: { due_on: (Date.today + 90).to_s } }
    assert_equal original, mine.reload.due_on
    get edit_admin_course_assignment_path(mine)
    assert_redirected_to admin_course_assignments_path

    patch admin_course_assignment_path(@assignment), params: { course_assignment: { due_on: (Date.today + 90).to_s } }
    assert_equal Date.today + 90, @assignment.reload.due_on
  end

  test "update tolerates a malformed course_assignment param" do
    sign_in @admin
    original = @assignment.due_on
    patch admin_course_assignment_path(@assignment), params: { course_assignment: "x" }
    assert_equal original, @assignment.reload.due_on
  end

  test "a double submit does not 500 when a person ticks a step" do
    StepCompletion.stubs(:create!).raises(ActiveRecord::RecordNotUnique)
    sign_in @person
    post complete_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
  end

  test "a double submit does not 500 when an admin marks a step done" do
    StepCompletion.stubs(:create!).raises(ActiveRecord::RecordNotUnique)
    sign_in @admin
    post complete_step_for_admin_course_assignment_path(@assignment, step_id: @auto.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
  end

  test "a double submit does not 500 when an admin signs off" do
    complete_step!(@person, @read)
    complete_step!(@person, @auto, source: "auto")
    StepCompletion.stubs(:create!).raises(ActiveRecord::RecordInvalid)
    sign_in @admin
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
  end

  # ── quick check review gating ─────────────────────────────────────────────

  test "a module completion without a passed attempt does not unlock explanations" do
    ModuleCompletion.create!(admin_user: @person, learning_module: @mod, completed_at: Time.current)
    sign_in @person
    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_redirected_to admin_course_assignment_path(@assignment)
    assert_not_includes response.body, "Because 0."
  end

  test "an admin cannot preview answers on their own checklist before taking it" do
    mine = learning_assign!(@admin, @course)
    sign_in @admin
    get quiz_admin_course_assignment_path(mine, learning_module_id: @mod.id)
    assert_redirected_to admin_course_assignment_path(mine)
    assert_not_includes response.body, "Because 0."
  end

  test "an admin can review someone else's locked quick check" do
    [@read, @auto, @sign_off].each { |s| complete_step!(@person, s) }
    2.times { QuizAttempt.create!(admin_user: @person, learning_module: @mod, correct_count: 0, question_count: 2) }
    sign_in @admin
    get quiz_admin_course_assignment_path(@assignment, learning_module_id: @mod.id)
    assert_response :success
    assert_includes response.body, "Because 0."
  end

  # ── past project leads (the blanket grant in AdminAuthorization) ──────────

  test "a lead who is not an admin cannot see someone else's checklist, the index, or act on it" do
    lead = lead!
    sign_in lead
    get admin_admin_user_path(@person)
    assert_response :success, "positive control: leads really do pass the blanket grant"

    get admin_course_assignment_path(@assignment)
    assert_not_equal 200, response.status
    get admin_course_assignments_path
    assert_not_equal 200, response.status
    post complete_step_admin_course_assignment_path(@assignment, step_id: @read.id)
    assert_not done?(@person, @read)
    post waive_admin_course_assignment_path(@assignment)
    assert_nil @assignment.reload.waived_at
    complete_step!(@person, @read)
    complete_step!(@person, @auto, source: "auto")
    post sign_off_step_admin_course_assignment_path(@assignment, step_id: @sign_off.id)
    assert_not done?(@person, @sign_off), "the sign-off was ready"
  end

  test "an overdue task links to the checklist" do
    task = StacksTask.new(type: :course_assignment_overdue, subject: @assignment, owners: [@person])
    assert_equal admin_course_assignment_path(@assignment), task.subject_url
  end
end
