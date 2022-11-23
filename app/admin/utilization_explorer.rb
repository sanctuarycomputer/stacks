ActiveAdmin.register_page "Utilization Explorer" do
  belongs_to :studio

  content title: proc { I18n.t("active_admin.utilization_explorer") } do
    all_gradations = ["month", "quarter", "year"]
    default_gradation = "month"
    current_gradation =
      params["gradation"] || default_gradation
    current_gradation =
      default_gradation unless all_gradations.include?(current_gradation)

    studio = Studio.find(params[:studio_id])
    render(partial: "utilization_explorer", locals: {
      all_gradations: all_gradations,
      default_gradation: default_gradation,
      snapshot: studio.snapshot
    })
  end
end
