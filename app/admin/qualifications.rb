ActiveAdmin.register Qualification do
  menu label: "Qualifications & Badges", parent: "Onboarding", priority: 4, if: proc { current_admin_user.is_admin? }
  permit_params :name, :description, :kind
  config.filters = false

  index download_links: false do
    column :name
    column :kind
    column :holders do |q|
      q.qualification_grants.count
    end
    actions
  end

  form do |f|
    f.semantic_errors
    f.inputs do
      f.input :name
      f.input :kind, as: :select, collection: Qualification::KINDS, include_blank: false,
        hint: "A course grants a qualification; a module grants a badge."
      f.input :description
    end
    f.actions
  end
end
