ActiveAdmin.register_page "Data Integrity Explorer" do
  menu label: "Data Integrity Explorer", parent: "System"

  content title: proc { I18n.t("active_admin.data_integrity_explorer") } do
    problems = Stacks::DataIntegrityManager.new.discover_problems

    all_data_types = problems.keys.map(&:to_s)
    default_data_type = all_data_types.first
    current_data_type = params["data_type"] || default_data_type

    render(partial: "data_integrity_explorer", locals: {
      all_data_types: all_data_types,
      default_data_type: default_data_type,
      current_data_type: current_data_type,
    }.merge(problems))
  end
end
