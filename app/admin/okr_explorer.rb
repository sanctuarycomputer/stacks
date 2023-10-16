ActiveAdmin.register_page "OKR Explorer" do
  belongs_to :studio

  content title: proc { I18n.t("active_admin.okr_explorer") } do
    all_gradations = ["month", "quarter", "year", "trailing_3_months", "trailing_4_months", "trailing_6_months", "trailing_12_months"]
    default_gradation = "month"

    all_okrs = ["average_hourly_rate", "sellable_hours_sold", "cost_per_sellable_hour"]
    default_okr = "average_hourly_rate"

    studio = Studio.find(params[:studio_id])
    g3d = Studio.garden3d

    accounting_method = session[:accounting_method] || "cash"

    render(partial: "okr_explorer", locals: {
      all_gradations: all_gradations,
      default_gradation: all_gradations.first,
      studio: studio,
      accounting_method: accounting_method,

      all_okrs: all_okrs,
      default_okr: all_okrs.first,

      snapshot: studio.snapshot,
      g3d_snapshot: g3d.snapshot,
    })
  end
end
