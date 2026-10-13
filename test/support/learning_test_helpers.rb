# Builders for the onboarding-course models. Included into every test case.
module LearningTestHelpers
  # A plain company-email person (not an admin, no full-time period).
  def learning_person!(prefix: "newbie", roles: [])
    AdminUser.create!(email: "#{prefix}#{SecureRandom.hex(4)}@sanctuary.computer",
                      password: "password12345", password_confirmation: "password12345",
                      roles: roles)
  end

  # steps: array of kinds or [kind, auto_check_key] pairs. questions: how many
  # (each has 4 choices, correct_index 0).
  def learning_module!(slug: "m-#{SecureRandom.hex(4)}", steps: ["read"], questions: 0,
                       pass_percent: 80, qualification: nil)
    mod = LearningModule.create!(name: slug.titleize, slug: slug, quiz_pass_percent: pass_percent,
                                 qualification: qualification)
    steps.each_with_index do |spec, i|
      kind, key = Array(spec)
      mod.module_steps.create!(position: i, kind: kind, title: "#{kind} #{i}", auto_check_key: key)
    end
    questions.times do |i|
      mod.quiz_questions.create!(position: i, prompt: "Question #{i}?",
                                 choices: %w[right wrong1 wrong2 wrong3], correct_index: 0,
                                 explanation: "Because #{i}.")
    end
    mod.reload
  end

  def learning_course!(modules:, slug: "c-#{SecureRandom.hex(4)}", auto_assign: false, qualification: nil)
    course = Course.create!(name: slug.titleize, slug: slug, learner_title: "Getting on board (#{slug})",
                            auto_assign: auto_assign, qualification: qualification)
    modules.each_with_index { |m, i| course.course_modules.create!(learning_module: m, position: i) }
    course.reload
  end

  def learning_assign!(person, course, assigned_on: Date.today, due_on: nil)
    CourseAssignment.create!(admin_user: person, course: course, assigned_on: assigned_on, due_on: due_on)
  end

  # The hidden field the quick-check form carries; web posts must include it.
  def quiz_fingerprint(learning_module)
    Stacks::Learning::Quiz.fingerprint(learning_module.reload)
  end

  def complete_step!(person, step, source: "self", by: nil)
    StepCompletion.create!(admin_user: person, module_step: step, completed_at: Time.current,
                           source: source, completed_by: by)
  end
end

ActiveSupport::TestCase.include(LearningTestHelpers)
