require "test_helper"

class StacksTaskBuilderCourseAssignmentsDiscoveryTest < ActiveSupport::TestCase
  D = Stacks::TaskBuilder::Discoveries::CourseAssignments

  setup do
    @admin = build_admin!
    @person = learning_person!
    @mod = learning_module!(steps: ["read"])
    @course = learning_course!(modules: [@mod])
  end

  def tasks
    D.new(admin_fallback: AdminUser.admin.to_a).tasks.select { |t| t.subject.course_id == @course.id || @extra_course_ids.to_a.include?(t.subject.course_id) }
  end

  def types
    tasks.map(&:type)
  end

  test "not overdue on or before the due date, overdue the day after" do
    a = learning_assign!(@person, @course, due_on: Date.today)
    assert_empty types
    a.update!(due_on: Date.today - 1)
    assert_equal [D::OVERDUE], types
    assert_equal [@person], tasks.first.owners
    assert_equal a, tasks.first.subject
  end

  test "completed and waived assignments produce nothing" do
    a = learning_assign!(@person, @course, due_on: Date.today - 1)
    a.update!(completed_at: Time.current)
    assert_empty types
    a.update!(completed_at: nil, waived_at: Time.current)
    assert_empty types
  end

  test "an ignored person and a departed person are skipped; a brand-new person with no period is not" do
    learning_assign!(@person, @course, due_on: Date.today - 1)
    assert_equal [D::OVERDUE], types, "no full-time periods yet: still eligible"

    @person.update!(ignore: true)
    assert_empty types
    @person.update!(ignore: false)

    FullTimePeriod.create!(admin_user: @person, started_at: Date.today - 60, ended_at: Date.today - 30,
                           contributor_type: Enum::ContributorType::VARIABLE_HOURS, expected_utilization: 0)
    assert_empty types, "their only period has ended"

    FullTimePeriod.create!(admin_user: @person, started_at: Date.today - 5, ended_at: nil,
                           contributor_type: Enum::ContributorType::VARIABLE_HOURS, expected_utilization: 0)
    assert_equal [D::OVERDUE], types
  end

  test "not overdue when only an admin sign-off remains; the sign-off task goes to admins" do
    mod = learning_module!(steps: ["read", "admin_sign_off"])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today - 1)
    complete_step!(@person, mod.module_steps.first)

    found = tasks.select { |t| t.subject == a }
    assert_equal [D::SIGN_OFF], found.map(&:type)
    assert_includes found.first.owners, @admin
    assert_not_includes found.first.owners, @person
  end

  test "not overdue when the only thing left is a locked quiz" do
    mod = learning_module!(steps: ["read"], questions: 1)
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today - 1)
    complete_step!(@person, mod.module_steps.first)
    assert_equal [D::OVERDUE], tasks.select { |t| t.subject == a }.map(&:type), "quiz open: theirs"
    2.times { QuizAttempt.create!(admin_user: @person, learning_module: mod, correct_count: 0, question_count: 1) }
    found = tasks.select { |t| t.subject == a }
    assert_equal [D::SIGN_OFF], found.map(&:type), "locked and past due: the admins are told, the person is not overdue"
    assert_not_includes found.first.owners, @person
  end

  test "a locked quiz before the due date tells nobody" do
    mod = learning_module!(steps: ["read"], questions: 1)
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course)
    complete_step!(@person, mod.module_steps.first)
    2.times { QuizAttempt.create!(admin_user: @person, learning_module: mod, correct_count: 0, question_count: 1) }
    assert_empty tasks.select { |t| t.subject == a }
  end

  test "admins are not told to link a payment profile while the person still has their own steps to do" do
    mod = learning_module!(steps: [["auto_check", "forecast_account"], ["auto_check", "payment_profile"]])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today - 1)
    assert_equal [D::OVERDUE], tasks.select { |t| t.subject == a }.map(&:type)
  end

  test "a sign-off that is not ready yet produces no admin task" do
    mod = learning_module!(steps: ["read", "admin_sign_off"])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course)
    assert_empty tasks.select { |t| t.subject == a }
  end

  test "an admin never owns the sign-off task on their own assignment, and it is dropped if nobody else can" do
    mod = learning_module!(steps: ["admin_sign_off"])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@admin, course)

    only_self = D.new(admin_fallback: [@admin]).tasks.select { |t| t.subject == a }
    assert_empty only_self

    second = build_admin!(email_prefix: "second")
    both = D.new(admin_fallback: [@admin, second]).tasks.select { |t| t.subject == a }
    assert_equal [[second]], both.map(&:owners)
  end

  test "both tasks can exist at once" do
    mod = learning_module!(steps: ["admin_sign_off", "read"])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today - 1)
    assert_equal [D::OVERDUE, D::SIGN_OFF].sort, tasks.select { |t| t.subject == a }.map(&:type).sort
  end

  test "task labels, display name and url" do
    a = learning_assign!(@person, @course, due_on: Date.today - 1)
    task = tasks.first
    assert_equal "Assigned checklist is overdue", task.humanized_type
    assert_equal "#{@person.email} — #{@course.learner_title}", task.subject_display_name
    assert_equal "#{@person.email} — #{@course.learner_title}", task.subject_display_name(redact_amounts: true)
    assert_equal "course_assignments", task.subject_class_key
    assert_equal "Checklist is waiting on an admin", StacksTask::HUMANIZED_TYPES[D::SIGN_OFF]
  end

  test "past due with only an admin-owned auto-check left: no overdue for the person, a sign-off task for admins" do
    mod = learning_module!(steps: [["auto_check", "payment_profile"]])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today - 1)

    found = tasks.select { |t| t.subject == a }
    assert_equal [D::SIGN_OFF], found.map(&:type)
    assert_includes found.first.owners, @admin
    assert_not_includes found.first.owners, @person

    complete_step!(@person, mod.module_steps.first, source: "auto")
    assert_empty tasks.select { |t| t.subject == a }
  end

  test "before the due date an admin-owned auto-check produces no tasks" do
    mod = learning_module!(steps: [["auto_check", "payment_profile"]])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today + 3)
    assert_empty tasks.select { |t| t.subject == a }
  end

  test "past due with a person-owned auto-check left is overdue for the person" do
    mod = learning_module!(steps: [["auto_check", "forecast_account"], ["auto_check", "payment_profile"]])
    course = learning_course!(modules: [mod])
    @extra_course_ids = [course.id]
    a = learning_assign!(@person, course, due_on: Date.today - 1)
    # Admins are told only once the person has nothing of their own left.
    assert_equal [D::OVERDUE], tasks.select { |t| t.subject == a }.map(&:type)
  end

  test "the discovery is registered" do
    assert_includes Stacks::TaskBuilder::DISCOVERY_CLASSES, D
  end
end
