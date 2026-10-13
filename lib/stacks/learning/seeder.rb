module Stacks
  module Learning
    # Builds a course from a YAML file. Create-only, so it is safe to re-run:
    #   - a qualification is matched by name, a course and a module by slug;
    #   - a module that already exists is left entirely alone (steps and
    #     questions included);
    #   - the course's module list is written only when the course is created.
    # Anything an admin has since edited or removed therefore stays that way.
    class Seeder
      def self.call(path)
        data = YAML.load_file(path)

        ActiveRecord::Base.transaction do
          modules = data.fetch("modules").map { |attrs| ensure_module(attrs) }

          course_attrs = data.fetch("course")
          course = Course.find_by(slug: course_attrs.fetch("slug"))
          next course if course

          qualification = ensure_qualification(data.dig("qualification", "name"), "qualification", data.dig("qualification", "description"))
          course = Course.create!(
            name: course_attrs.fetch("name"),
            slug: course_attrs.fetch("slug"),
            learner_title: course_attrs.fetch("learner_title"),
            description: course_attrs["description"],
            grace_period_days: course_attrs.fetch("grace_period_days", 14),
            auto_assign: false,
            qualification: qualification,
          )
          modules.each_with_index do |learning_module, index|
            course.course_modules.create!(learning_module: learning_module, position: index)
          end
          course
        end
      end

      def self.ensure_module(attrs)
        existing = LearningModule.find_by(slug: attrs.fetch("slug"))
        return existing if existing

        badge = ensure_qualification(attrs["badge"], "badge", nil)
        learning_module = LearningModule.create!(
          name: attrs.fetch("name"), slug: attrs.fetch("slug"), summary: attrs["summary"],
          notion_url: attrs["notion_url"], qualification: badge,
        )
        Array(attrs["steps"]).each_with_index do |step, index|
          learning_module.module_steps.create!(
            position: index, kind: step.fetch("kind"), title: step.fetch("title"),
            notion_url: step["notion_url"], auto_check_key: step["auto_check_key"],
          )
        end
        Array(attrs["questions"]).each_with_index do |question, index|
          learning_module.quiz_questions.create!(
            position: index, prompt: question.fetch("prompt"), choices: question.fetch("choices"),
            correct_index: question.fetch("correct_index"), explanation: question["explanation"],
          )
        end
        learning_module
      end
      private_class_method :ensure_module

      def self.ensure_qualification(name, kind, description)
        return nil if name.blank?
        Qualification.find_by(name: name) || Qualification.create!(name: name, kind: kind, description: description)
      end
      private_class_method :ensure_qualification
    end
  end
end
