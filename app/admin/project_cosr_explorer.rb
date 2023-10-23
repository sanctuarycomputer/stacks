ActiveAdmin.register_page "Project COSR Explorer" do
  belongs_to :project_tracker

  # TODO: Why does the latest month have no hours?
  # TODO: Link to explorer from ProjectTracker
  # TODO: Support project_to_date gradation
  # TODO: Add Total for period-level
  content title: proc { I18n.t("active_admin.project_cosr_explorer") } do
    accounting_method = session[:accounting_method] || "cash"
    all_gradations = ["month", "project_to_date"]
    default_gradation = "month"
    current_gradation = params["gradation"] || default_gradation

    project_tracker = ProjectTracker.find(params[:project_tracker_id])
    cosr = project_tracker.cost_of_services_rendered(current_gradation)

    render(partial: "project_cosr_explorer", locals: {
      all_gradations: all_gradations,
      default_gradation: all_gradations.first,
      current_gradation: current_gradation,
      cosr: cosr,
      accounting_method: accounting_method,
    })
  end
end
