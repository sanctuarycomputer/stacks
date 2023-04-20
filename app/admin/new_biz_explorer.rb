ActiveAdmin.register_page "New Biz Explorer" do
  belongs_to :studio

  content title: proc { I18n.t("active_admin.new_biz_explorer") } do
    all_gradations = ["month", "quarter", "year", "trailing_3_months", "trailing_4_months", "trailing_6_months", "trailing_12_months"]
    default_gradation = "month"
    current_gradation = params["gradation"] || default_gradation

    all_okrs = ["average_hourly_rate", "sellable_hours_sold"]
    default_okr = "average_hourly_rate"
    studio = Studio.find(params[:studio_id])
    new_biz_cards = studio.new_biz_notion_pages

    current_gradation = default_gradation unless all_gradations.include?(current_gradation)
    periods = Stacks::Period.for_gradation(current_gradation.to_sym)

    status_history_by_period = 
      new_biz_cards.reduce({}) do |acc, card|
        card.status_history.each do |status|
          period = periods.find{|p| p.include?(status[:changed_at]) }
          if period.present?
            acc[period] = acc[period] || []
            acc[period] << status.merge({ 
              page_title: card.page_title, 
              url: card.data["url"] 
            })
          end
        end
        acc
      end

    render(partial: "new_biz_explorer", locals: {
      all_gradations: all_gradations,
      default_gradation: all_gradations.first,

      all_okrs: all_okrs,
      default_okr: all_okrs.first,

      status_history_by_period: status_history_by_period,
      periods: periods,
    })
  end
end
