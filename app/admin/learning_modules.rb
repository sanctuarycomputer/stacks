ActiveAdmin.register LearningModule do
  menu label: "Modules", parent: "Onboarding", priority: 3, if: proc { current_admin_user.is_admin? }
  permit_params :name, :slug, :summary, :notion_url, :quiz_pass_percent, :qualification_id,
    module_steps_attributes: [:id, :position, :kind, :title, :notion_url, :auto_check_key, :_destroy],
    quiz_questions_attributes: [:id, :position, :prompt, :choices_text, :correct_index, :explanation, :_destroy]
  config.filters = false

  index download_links: false do
    column :name
    column :slug
    column :steps do |m|
      m.module_steps.size
    end
    column :questions do |m|
      m.quiz_questions.size
    end
    column :courses do |m|
      m.courses.map(&:name).join(", ")
    end
    actions
  end

  show do
    attributes_table do
      row :name
      row :slug
      row :summary
      row :notion_url
      row :quiz_pass_percent
      row :qualification
    end
    panel "Steps" do
      table_for resource.module_steps do
        column :position
        column :kind
        column :title
        column :auto_check_key
        column :notion_url
      end
    end
    panel "Quiz questions" do
      table_for resource.quiz_questions do
        column :position
        column :prompt
        column :choices do |q|
          q.choices.each_with_index.map { |c, i| i == q.correct_index ? "✔ #{c}" : c }.join(" · ")
        end
        column :explanation
      end
    end
  end

  form do |f|
    f.semantic_errors
    f.inputs "Module" do
      f.input :name
      f.input :slug, hint: "Stable identifier. Don't change it once people have started."
      f.input :summary, hint: "Markdown. Shown to the person above the steps."
      f.input :notion_url
      f.input :quiz_pass_percent, hint: "Only used if the module has questions."
      f.input :qualification, as: :select, collection: Qualification.where(kind: "badge").order(:name),
        hint: "Optional badge granted when someone finishes this module."
    end
    f.has_many :module_steps, heading: "Steps", allow_destroy: true, new_record: "Add a step" do |s|
      s.input :position
      s.input :kind, as: :select, collection: ModuleStep::KINDS, include_blank: false
      s.input :title, hint: "Phrase it as an action for the person."
      s.input :notion_url
      s.input :auto_check_key, as: :select, collection: Stacks::Learning::AutoChecks.options_for_select,
        include_blank: true, hint: "Only for auto_check steps."
    end
    f.has_many :quiz_questions, heading: "Quiz questions", allow_destroy: true, new_record: "Add a question" do |q|
      q.input :position
      q.input :prompt
      q.input :choices_text, as: :text, label: "Choices", hint: "One per line, 2 to 6.", input_html: { rows: 5 }
      q.input :correct_index, hint: "0 is the first choice."
      q.input :explanation, hint: "Shown only after the person passes."
    end
    f.actions
  end
end
