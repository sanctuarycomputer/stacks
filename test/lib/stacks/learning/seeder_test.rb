require "test_helper"

class StacksLearningSeederTest < ActiveSupport::TestCase
  PATH = Rails.root.join("db/seeds/learning/wayfinding.yml")
  DATA = YAML.load_file(PATH)

  test "the YAML is well formed: registered auto-check keys, valid kinds, 5 questions where there is a quiz" do
    DATA["modules"].each do |mod|
      mod["steps"].each do |step|
        assert_includes ModuleStep::KINDS, step["kind"], mod["slug"]
        if step["kind"] == "auto_check"
          assert_includes Stacks::Learning::AutoChecks.keys, step["auto_check_key"], mod["slug"]
        else
          assert_nil step["auto_check_key"], mod["slug"]
        end
      end
      assert_includes [0, 5], mod["questions"].size, mod["slug"]
      mod["questions"].each do |q|
        assert_equal 4, q["choices"].size, q["prompt"]
        assert_includes 0..3, q["correct_index"], q["prompt"]
        assert q["explanation"].present?, q["prompt"]
      end
    end
  end

  test "person-facing copy avoids training language" do
    texts = [DATA["course"]["learner_title"], DATA["course"]["description"], DATA.dig("qualification", "name")]
    DATA["modules"].each do |mod|
      texts << mod["name"] << mod["summary"] << mod["badge"]
      mod["steps"].each { |s| texts << s["title"] }
      mod["questions"].each do |q|
        texts << q["prompt"] << q["explanation"]
        texts.concat(q["choices"])
      end
    end
    texts.compact.each do |text|
      assert_no_match(/\b(courses?|lessons?|trainings?|learners?|quiz(zes)?)\b/i, text)
    end
  end

  test "seeding builds Wayfinding: six modules in order, not auto-assigned" do
    course = Stacks::Learning::Seeder.call(PATH)
    assert_equal "wayfinding", course.slug
    assert_equal "Getting on board at garden3d", course.learner_title
    assert_not course.auto_assign
    assert_equal 14, course.grace_period_days
    assert_equal "Onboarded to garden3d", course.qualification.name
    assert_equal "qualification", course.qualification.kind
    assert_equal %w[paperwork-and-payment your-accounts how-you-get-paid policies how-we-communicate onboarding-sign-off],
                 course.ordered_modules.map(&:slug)
    assert_equal [2, 4, 4, 4, 5, 1], course.ordered_modules.map { |m| m.module_steps.size }
    assert_equal [0, 0, 5, 5, 5, 0], course.ordered_modules.map { |m| m.quiz_questions.size }
    paid = LearningModule.find_by!(slug: "how-you-get-paid")
    assert_equal ["How you get paid", "badge"], [paid.qualification.name, paid.qualification.kind]
    assert_nil LearningModule.find_by!(slug: "your-accounts").qualification
    first = LearningModule.find_by!(slug: "paperwork-and-payment").module_steps.to_a
    assert_equal %w[admin_sign_off auto_check], first.map(&:kind)
    assert_equal "payment_profile", first.last.auto_check_key
  end

  test "seeding twice creates nothing new" do
    Stacks::Learning::Seeder.call(PATH)
    counts = -> { [Course, LearningModule, CourseModule, ModuleStep, QuizQuestion, Qualification].map(&:count) }
    before = counts.call
    Stacks::Learning::Seeder.call(PATH)
    assert_equal before, counts.call
  end

  test "re-seeding never overwrites admin edits or re-adds removed rows" do
    course = Stacks::Learning::Seeder.call(PATH)
    course.update!(auto_assign: true, learner_title: "Edited title")
    mod = LearningModule.find_by!(slug: "policies")
    mod.update!(name: "Edited name")
    mod.quiz_questions.first.destroy!
    step = mod.module_steps.first
    step.update!(title: "Edited step")

    sign_off = LearningModule.find_by!(slug: "onboarding-sign-off")
    course.course_modules.find_by!(learning_module: sign_off).destroy!
    sign_off.destroy!
    counts = -> { [Course, LearningModule, CourseModule, ModuleStep, QuizQuestion, Qualification].map(&:count) }
    before = counts.call

    Stacks::Learning::Seeder.call(PATH)

    assert_nil LearningModule.find_by(slug: "onboarding-sign-off")
    assert_equal before, counts.call
    course.reload
    assert course.auto_assign
    assert_equal "Edited title", course.learner_title
    assert_equal "Edited name", mod.reload.name
    assert_equal 4, mod.quiz_questions.count
    assert_equal "Edited step", step.reload.title
    assert_equal 5, course.course_modules.count
  end

  test "a newly seeded person can be assigned it and the first sign-off is ready at once" do
    course = Stacks::Learning::Seeder.call(PATH)
    person = learning_person!
    assignment = learning_assign!(person, course)
    checklist = Stacks::Learning::Checklist.new(assignment)
    assert_equal 20, checklist.steps_total
    assert_equal ["Your signed GCA is on file"], checklist.ready_sign_off_steps.map(&:title)
  end
end
