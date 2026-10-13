ActiveAdmin.register Course do
  menu label: "Courses", parent: "Onboarding", priority: 2, if: proc { current_admin_user.is_admin? }
  permit_params :name, :slug, :learner_title, :description, :grace_period_days, :auto_assign, :qualification_id,
    course_modules_attributes: [:id, :learning_module_id, :position, :_destroy]
  config.filters = false

  index download_links: false do
    column :name
    column :learner_title
    column :auto_assign
    column :grace_period_days
    column :modules do |c|
      c.course_modules.size
    end
    column :assigned do |c|
      c.course_assignments.count
    end
    actions
  end

  show do
    attributes_table do
      row :name
      row :slug
      row :learner_title
      row :description
      row :grace_period_days
      row :auto_assign
      row :qualification
    end
    panel "Modules" do
      table_for resource.course_modules.includes(:learning_module) do
        column :position
        column :module do |cm|
          link_to cm.learning_module.name, admin_learning_module_path(cm.learning_module)
        end
      end
    end
  end

  form do |f|
    f.semantic_errors
    f.inputs "Course" do
      f.input :name
      f.input :slug
      f.input :learner_title, hint: "What the assigned person sees. Avoid the words course, training and quiz."
      f.input :description, hint: "Markdown. Shown to the person at the top of their checklist."
      f.input :grace_period_days, hint: "Days from assignment until it's due."
      f.input :auto_assign, hint: "Assign to every newly discovered company-email person. Existing people are not affected."
      f.input :qualification, as: :select, collection: Qualification.where(kind: "qualification").order(:name)
    end
    f.has_many :course_modules, heading: "Modules", allow_destroy: true, new_record: "Add a module" do |cm|
      cm.input :position
      cm.input :learning_module, as: :select, collection: LearningModule.order(:name)
    end
    f.actions
  end
end
