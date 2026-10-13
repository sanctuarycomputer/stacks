require "test_helper"

class LearningModelsTest < ActiveSupport::TestCase
  test "a step's kind must be one of the four kinds" do
    mod = learning_module!(steps: [])
    step = mod.module_steps.build(position: 0, kind: "watch", title: "x")
    assert_not step.valid?
    assert_includes step.errors[:kind], "is not included in the list"
  end

  test "an auto_check step needs a registered key, and other kinds must not have one" do
    mod = learning_module!(steps: [])
    assert_not mod.module_steps.build(position: 0, kind: "auto_check", title: "x").valid?
    assert_not mod.module_steps.build(position: 0, kind: "auto_check", title: "x", auto_check_key: "nope").valid?
    assert mod.module_steps.build(position: 0, kind: "auto_check", title: "x", auto_check_key: "forecast_account").valid?
    assert_not mod.module_steps.build(position: 0, kind: "read", title: "x", auto_check_key: "forecast_account").valid?
  end

  test "a question needs 2-6 non-blank choices and a correct_index inside them" do
    mod = learning_module!(steps: [])
    base = { position: 0, prompt: "?" }
    assert_not mod.quiz_questions.build(base.merge(choices: ["only"], correct_index: 0)).valid?
    assert_not mod.quiz_questions.build(base.merge(choices: ["a", ""], correct_index: 0)).valid?
    assert_not mod.quiz_questions.build(base.merge(choices: %w[a b], correct_index: 2)).valid?
    assert_not mod.quiz_questions.build(base.merge(choices: %w[a b c d e f g], correct_index: 0)).valid?
    assert mod.quiz_questions.build(base.merge(choices: %w[a b], correct_index: 1)).valid?
  end

  test "choices_text round-trips one choice per line and drops blank lines" do
    q = QuizQuestion.new(choices_text: "one\n\n two \nthree\n")
    assert_equal %w[one two three], q.choices
    assert_equal "one\ntwo\nthree", q.choices_text
  end

  test "an assignment defaults assigned_on to today and due_on to the course's grace period" do
    course = learning_course!(modules: [learning_module!])
    course.update!(grace_period_days: 14)
    a = CourseAssignment.create!(admin_user: learning_person!, course: course)
    assert_equal Date.today, a.assigned_on
    assert_equal Date.today + 14, a.due_on
  end

  test "a person can be assigned a course only once" do
    course = learning_course!(modules: [learning_module!])
    person = learning_person!
    learning_assign!(person, course)
    assert_raises(ActiveRecord::RecordInvalid) { learning_assign!(person, course) }
  end

  test "outstanding excludes completed and waived assignments" do
    course = learning_course!(modules: [learning_module!])
    open_a = learning_assign!(learning_person!, course)
    done = learning_assign!(learning_person!, course)
    done.update!(completed_at: Time.current)
    waived = learning_assign!(learning_person!, course)
    waived.update!(waived_at: Time.current)
    assert_equal [open_a], CourseAssignment.outstanding.where(course: course).to_a
    assert open_a.outstanding?
    assert_not done.outstanding?
    assert_not waived.outstanding?
  end

  test "ordered_modules and module_steps come back by position then id" do
    a = learning_module!(steps: [])
    b = learning_module!(steps: [])
    course = Course.create!(name: "Ordered", slug: "ordered", learner_title: "x")
    course.course_modules.create!(learning_module: a, position: 2)
    course.course_modules.create!(learning_module: b, position: 1)
    assert_equal [b, a], course.reload.ordered_modules
    s2 = a.module_steps.create!(position: 5, kind: "read", title: "later")
    s1 = a.module_steps.create!(position: 1, kind: "read", title: "sooner")
    assert_equal [s1, s2], a.reload.module_steps.to_a
  end

  test "a step with completions cannot be destroyed" do
    mod = learning_module!(steps: ["read"])
    step = mod.module_steps.first
    complete_step!(learning_person!, step)
    assert_not step.destroy
    assert ModuleStep.exists?(step.id)
  end

  test "a module refuses, without raising, to drop a completed step or to be destroyed with progress" do
    mod = learning_module!(steps: ["read", "do"])
    done_step, other_step = mod.module_steps.to_a
    complete_step!(learning_person!, done_step)

    assert_not mod.update(module_steps_attributes: [{ id: done_step.id, _destroy: "1" }])
    assert_match(/completed/, mod.errors.full_messages.join)
    assert ModuleStep.exists?(done_step.id)

    assert mod.reload.update(module_steps_attributes: [{ id: other_step.id, _destroy: "1" }])
    assert_not ModuleStep.exists?(other_step.id)

    assert_not mod.reload.destroy
    assert LearningModule.exists?(mod.id)
  end

  test "destroying a person removes their own progress and nulls where they were the actor" do
    badge = Qualification.create!(name: "Badge #{SecureRandom.hex(3)}", kind: "badge")
    mod = learning_module!(steps: ["admin_sign_off"], questions: 1)
    course = learning_course!(modules: [mod])
    leaver = learning_person!(prefix: "leaver", roles: ["admin"])
    other = learning_person!(prefix: "other")

    # leaver's own rows
    own = learning_assign!(leaver, course)
    QuizAttempt.create!(admin_user: leaver, learning_module: mod, correct_count: 0, question_count: 1)
    ModuleCompletion.create!(admin_user: leaver, learning_module: mod, completed_at: Time.current)
    # rows where leaver was the actor on someone else
    theirs = learning_assign!(other, course)
    theirs.update!(assigned_by: leaver, waived_by: leaver, waived_at: Time.current)
    sc = complete_step!(other, mod.module_steps.first, source: "admin", by: leaver)
    retry_grant = QuizRetryGrant.create!(admin_user: other, learning_module: mod, granted_by: leaver)
    grant = QualificationGrant.create!(admin_user: other, qualification: badge, granted_at: Time.current, granted_by: leaver)

    leaver.destroy!

    assert_not CourseAssignment.exists?(own.id)
    assert_equal 0, QuizAttempt.where(admin_user_id: leaver.id).count
    assert_equal 0, ModuleCompletion.where(admin_user_id: leaver.id).count
    assert_nil theirs.reload.assigned_by_id
    assert_nil theirs.waived_by_id
    assert_nil sc.reload.completed_by_id
    assert_nil retry_grant.reload.granted_by_id
    assert_nil grant.reload.granted_by_id
  end
end
