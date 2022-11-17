ActiveAdmin.register_page "Utilization Explorer" do
  belongs_to :studio

  content title: proc { I18n.t("active_admin.utilization_explorer") } do
    studio = Studio.find(params[:studio_id])

    # TODO: Consider "0.0" billing rate as non-billable
    # TODO: Expected Utilization should be historical
    data =
      [:month].reduce({}) do |acc, gradation|
        periods = Stacks::Period.for_gradation(gradation)
        acc[gradation] = {
          periods: periods,
          utilization: studio.utilization_by_people(periods)
        }
        acc
      end

    render(partial: "utilization_explorer", locals: {
      data: data
    })
  end
end
