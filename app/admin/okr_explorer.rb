ActiveAdmin.register_page "OKR Explorer" do
  belongs_to :studio

  content title: proc { I18n.t("active_admin.okr_explorer") } do
    all_gradations = ["month", "quarter", "year"]
    default_gradation = "month"

    all_okrs = ["average_hourly_rate", "sellable_hours_sold"]
    default_okr = "average_hourly_rate"

    studio = Studio.find(params[:studio_id])
    render(partial: "okr_explorer", locals: {
      all_gradations: all_gradations,
      default_gradation: all_gradations.first,

      all_okrs: all_okrs,
      default_okr: all_okrs.first,

      snapshot: studio.snapshot
    })
  end
end
