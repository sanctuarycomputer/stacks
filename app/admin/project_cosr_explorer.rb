ActiveAdmin.register_page "Project COSR Explorer" do
  belongs_to :project_tracker

  content title: proc { I18n.t("active_admin.project_cosr_explorer") } do
    project_tracker = ProjectTracker.find(params[:project_tracker_id])
    cosr = project_tracker.cost_of_services_rendered_new

    monthly_studio_rollups, forecast_person_ids, studio_ids = build_monthly_rollup(cosr)
    forecast_people = ForecastPerson.find(forecast_person_ids)
    studios = Studio.find(studio_ids)

    forecast_people_hash = forecast_people.reduce({}) do |acc, forecast_person|
      acc[forecast_person.id] = forecast_person
      acc
    end

    studios_hash = studios.reduce({}) do |acc, studio|
      acc[studio.id] = studio
      acc
    end

    render(partial: "project_cosr_explorer", locals: {
      monthly_studio_rollups: monthly_studio_rollups,
      studios: studios_hash,
      forecast_people: forecast_people_hash
    })
  end
end
