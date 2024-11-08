ActiveAdmin.register_page "OKR Explorer" do
  belongs_to :studio

  content title: proc { I18n.t("active_admin.okr_explorer") } do
    all_gradations = ["month", "quarter", "year", "trailing_3_months", "trailing_4_months", "trailing_6_months", "trailing_12_months"]
    default_gradation = "month"

    all_okrs = ["average_hourly_rate", "sellable_hours_sold", "cost_per_sellable_hour", "successful_projects", "successful_proposals"]
    default_okr = "average_hourly_rate"

    studio = Studio.find(params[:studio_id])
    g3d = Studio.garden3d

    accounting_method = session[:accounting_method] || "cash"

    current_okr = params["okr"] || default_okr
    current_gradation = params["gradation"] || default_gradation

    periods = Stacks::Period.for_gradation(current_gradation.to_sym)

    preloaded_studios = Studio.all
    all_projects_by_period = if current_okr == "successful_projects"
      periods.reduce({}) do |acc, period|
        acc[period] = studio.project_trackers_with_recorded_time_in_period(period, preloaded_studios)
        acc
      end
    end

    all_proposals_by_period = if current_okr == "successful_proposals"
      periods.reduce({}) do |acc, period|
        acc[period] = studio.sent_proposals_settled_in_period(period)
        acc
      end
    end

    render(partial: "okr_explorer", locals: {
      all_gradations: all_gradations,
      default_gradation: all_gradations.first,
      current_gradation: current_gradation,
      studio: studio,
      accounting_method: accounting_method,

      all_okrs: all_okrs,
      default_okr: all_okrs.first,
      current_okr: current_okr,

      snapshot: studio.snapshot,
      g3d_snapshot: g3d.snapshot,

      all_projects_by_period: all_projects_by_period,
      all_proposals_by_period: all_proposals_by_period
    })
  end
end
