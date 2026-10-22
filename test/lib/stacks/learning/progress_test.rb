require "test_helper"

class StacksLearningProgressTest < ActiveSupport::TestCase
  P = Stacks::Learning::Progress
  AC = Stacks::Learning::AutoChecks

  test "an auto_check that passes is completed with source auto; one that fails is not" do
    person = learning_person!
    mod = learning_module!(steps: [["auto_check", "forecast_account"], ["auto_check", "payment_profile"]])
    learning_assign!(person, learning_course!(modules: [mod]))
    AC.stubs(:passed?).with("forecast_account", person, anything).returns(true)
    AC.stubs(:passed?).with("payment_profile", person, anything).returns(false)

    P.refresh!(person)

    done = StepCompletion.where(admin_user: person)
    assert_equal [mod.module_steps.first.id], done.pluck(:module_step_id)
    assert_equal "auto", done.first.source
  end

  test "a module with no quiz completes when its steps are done, and grants its badge once" do
    badge = Qualification.create!(name: "Badge #{SecureRandom.hex(3)}", kind: "badge")
    person = learning_person!
    mod = learning_module!(steps: ["read"], qualification: badge)
    learning_assign!(person, learning_course!(modules: [mod, learning_module!]))

    P.refresh!(person)
    assert_equal 0, ModuleCompletion.where(admin_user: person).count

    complete_step!(person, mod.module_steps.first)
    P.refresh!(person)
    P.refresh!(person)
    assert_equal 1, ModuleCompletion.where(admin_user: person, learning_module: mod).count
    grants = QualificationGrant.where(admin_user: person, qualification: badge)
    assert_equal 1, grants.count
    assert_nil grants.first.granted_by_id
  end

  test "a module with a quiz does not complete until an attempt passes" do
    person = learning_person!
    mod = learning_module!(steps: ["read"], questions: 1)
    learning_assign!(person, learning_course!(modules: [mod]))
    complete_step!(person, mod.module_steps.first)
    P.refresh!(person)
    assert_equal 0, ModuleCompletion.where(admin_user: person).count

    QuizAttempt.create!(admin_user: person, learning_module: mod, correct_count: 1, question_count: 1, passed: true)
    P.refresh!(person)
    assert_equal 1, ModuleCompletion.where(admin_user: person).count
  end

  test "finishing every module completes the assignment and grants the qualification" do
    qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
    person = learning_person!
    m1 = learning_module!(steps: ["read"])
    m2 = learning_module!(steps: ["do"])
    a = learning_assign!(person, learning_course!(modules: [m1, m2], qualification: qual))

    complete_step!(person, m1.module_steps.first)
    P.refresh!(person)
    assert_nil a.reload.completed_at
    assert_equal 0, QualificationGrant.where(admin_user: person, qualification: qual).count

    complete_step!(person, m2.module_steps.first)
    P.refresh!(person)
    assert a.reload.completed_at.present?
    assert_equal 1, QualificationGrant.where(admin_user: person, qualification: qual).count
  end

  test "a module finished in one course counts in a second course" do
    person = learning_person!
    shared = learning_module!(steps: ["read"])
    learning_assign!(person, learning_course!(modules: [shared]))
    complete_step!(person, shared.module_steps.first)
    P.refresh!(person)

    second = learning_assign!(person, learning_course!(modules: [shared]))
    P.refresh!(person)
    assert second.reload.completed_at.present?
  end

  test "an existing manual grant is left untouched" do
    qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
    admin = learning_person!(prefix: "boss", roles: ["admin"])
    person = learning_person!
    manual = QualificationGrant.create!(admin_user: person, qualification: qual, granted_at: 1.year.ago, granted_by: admin, note: "by hand")
    mod = learning_module!(steps: ["read"])
    assignment = learning_assign!(person, learning_course!(modules: [mod], qualification: qual))
    complete_step!(person, mod.module_steps.first)

    P.refresh!(person)

    assert assignment.reload.completed_at.present?
    assert_equal [manual.id], QualificationGrant.where(admin_user: person, qualification: qual).pluck(:id)
    assert_equal admin.id, manual.reload.granted_by_id
    assert_equal "by hand", manual.note
  end

  test "waived assignments are skipped: nothing completes and nothing is granted" do
    qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
    person = learning_person!
    mod = learning_module!(steps: ["read"])
    a = learning_assign!(person, learning_course!(modules: [mod], qualification: qual))
    complete_step!(person, mod.module_steps.first)
    a.update!(waived_at: Time.current)

    P.refresh!(person)

    assert_nil a.reload.completed_at
    assert_equal 0, QualificationGrant.where(admin_user: person).count
    assert_equal 0, ModuleCompletion.where(admin_user: person).count
  end

  test "creating an assignment refreshes it, so an already-true auto check is done at once" do
    person = learning_person!
    mod = learning_module!(steps: [["auto_check", "forecast_account"]])
    AC.stubs(:passed?).returns(true)
    a = learning_assign!(person, learning_course!(modules: [mod]))
    assert a.reload.completed_at.present?
  end

  test "allow_for_admin_delay! pushes a near or past due date out, and leaves a comfortable one alone" do
    course = learning_course!(modules: [learning_module!])
    late = learning_assign!(learning_person!, course, due_on: Date.today - 5)
    P.allow_for_admin_delay!(late)
    assert_equal Date.today + P::ADMIN_DELAY_GRACE_DAYS, late.reload.due_on

    roomy = learning_assign!(learning_person!, course, due_on: Date.today + 10)
    P.allow_for_admin_delay!(roomy)
    assert_equal Date.today + 10, roomy.reload.due_on

    waived = learning_assign!(learning_person!, course, due_on: Date.today - 5)
    waived.update!(waived_at: Time.current)
    P.allow_for_admin_delay!(waived)
    assert_equal Date.today - 5, waived.reload.due_on
  end

  test "an admin-owned check passing after the due date gives the person time for what it unblocks" do
    person = learning_person!
    mod = learning_module!(steps: [["auto_check", "payment_profile"]], questions: 1)
    a = learning_assign!(person, learning_course!(modules: [mod]), due_on: Date.today - 2)
    AC.stubs(:passed?).returns(true)

    P.refresh!(person)

    assert_equal Date.today + P::ADMIN_DELAY_GRACE_DAYS, a.reload.due_on
    assert_not Stacks::Learning::Checklist.new(a).overdue?, "the quiz just opened; they are not overdue for the admin's delay"
  end

  test "a person-owned check passing late does not move the due date" do
    person = learning_person!
    mod = learning_module!(steps: [["auto_check", "forecast_account"]], questions: 1)
    a = learning_assign!(person, learning_course!(modules: [mod]), due_on: Date.today - 2)
    AC.stubs(:passed?).returns(true)
    P.refresh!(person)
    assert_equal Date.today - 2, a.reload.due_on
  end

  test "refresh_all! covers everyone with an outstanding assignment and survives one person failing" do
    bad = learning_person!(prefix: "bad")
    good = learning_person!(prefix: "good")
    learning_assign!(bad, learning_course!(modules: [learning_module!(steps: [["auto_check", "forecast_account"]])]))
    good_mod = learning_module!(steps: ["read"])
    good_assignment = learning_assign!(good, learning_course!(modules: [good_mod]))
    complete_step!(good, good_mod.module_steps.first)
    # Stubbing passed? itself bypasses its internal rescue, so refresh! really
    # raises for the one person who has an auto_check step (created first, so
    # find_each reaches them first).
    AC.stubs(:passed?).raises(StandardError, "boom")

    assert_nothing_raised { P.refresh_all! }
    assert good_assignment.reload.completed_at.present?
  end

  test "a module completion without its badge grant is healed on the next refresh" do
    badge = Qualification.create!(name: "Badge #{SecureRandom.hex(3)}", kind: "badge")
    person = learning_person!
    mod = learning_module!(steps: ["read"], qualification: badge)
    learning_assign!(person, learning_course!(modules: [mod, learning_module!]))
    complete_step!(person, mod.module_steps.first)
    ModuleCompletion.create!(admin_user: person, learning_module: mod, completed_at: Time.current)
    assert_equal 0, QualificationGrant.where(admin_user: person, qualification: badge).count

    P.refresh!(person)

    assert_equal 1, QualificationGrant.where(admin_user: person, qualification: badge).count
  end

  test "a failed course grant leaves the assignment outstanding and a later refresh finishes it" do
    qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
    person = learning_person!
    mod = learning_module!(steps: ["read"])
    a = learning_assign!(person, learning_course!(modules: [mod], qualification: qual))
    complete_step!(person, mod.module_steps.first)

    QualificationGrant.stubs(:find_or_create_by!).raises(StandardError, "boom")
    assert_raises(StandardError) { P.refresh!(person) }
    assert_nil a.reload.completed_at

    QualificationGrant.unstub(:find_or_create_by!)
    P.refresh!(person)
    assert a.reload.completed_at.present?
    assert_equal 1, QualificationGrant.where(admin_user: person, qualification: qual).count
  end

  test "one assignment failing does not stop the person's other assignments" do
    qual = Qualification.create!(name: "Qual #{SecureRandom.hex(3)}", kind: "qualification")
    person = learning_person!
    m1 = learning_module!(steps: ["read"])
    m2 = learning_module!(steps: ["read"])
    first = learning_assign!(person, learning_course!(modules: [m1], qualification: qual))
    second = learning_assign!(person, learning_course!(modules: [m2]))
    complete_step!(person, m1.module_steps.first)
    complete_step!(person, m2.module_steps.first)

    QualificationGrant.stubs(:find_or_create_by!).raises(StandardError, "boom")
    assert_raises(StandardError) { P.refresh!(person) }

    assert_nil first.reload.completed_at
    assert second.reload.completed_at.present?
  end
end
