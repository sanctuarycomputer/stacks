ActiveAdmin.register_page "Admin User Key Metrics" do
  belongs_to :admin_user

  content title: "Key Metrics" do
    admin_user = AdminUser.find(params["admin_user_id"])

    all_gradations = ["month", "quarter", "year", "trailing_3_months", "trailing_4_months", "trailing_6_months", "trailing_12_months"]
    default_gradation = "month"
    current_gradation =
      params["gradation"] || default_gradation
    current_gradation =
      default_gradation unless all_gradations.include?(current_gradation)
    periods = Stacks::Period.for_gradation(current_gradation.to_sym)

    key_metrics_by_period =
      periods.reduce({}) do |acc, period|
        acc[period] = admin_user.key_metrics_for_period(period, current_gradation)
        acc
      end

    # Story Points Closed
    # Average time-to-close-PR
    # Skill Level

    COLORS = Stacks::Utils::COLORS

    skill_data = {
      labels: key_metrics_by_period.keys.map(&:label),
      datasets: [{
        label: 'PRs Merged',
        borderColor: COLORS[0],
        type: 'line',
        data: (key_metrics_by_period.values.map do |v|
          v[:prs_merged][:value]
        end),
        yAxisID: 'y',
      }, {
        label: 'Story Points Closed',
        borderColor: COLORS[0],
        type: 'bar',
        data: (key_metrics_by_period.values.map do |v|
          v[:story_points][:value]
        end),
        yAxisID: 'y',
      }, {
        label: 'Skill Band Points',
        borderColor: COLORS[1],
        type: 'line',
        data: (key_metrics_by_period.values.map do |v|
          v[:skill_points][:value]
        end),
        yAxisID: 'y1',
      }, {
        label: 'Time to Merge PR',
        borderColor: COLORS[2],
        type: 'line',
        data: (key_metrics_by_period.values.map do |v|
          v[:time_to_merge_pr][:value].to_f.round(2)
        end),
        yAxisID: 'y2',
      }]
    }

    utilization_data = {
      labels: key_metrics_by_period.keys.map(&:label),
      datasets: [{
        label: 'Utilization Rate (%)',
        borderColor: COLORS[4],
        data: (key_metrics_by_period.values.map do |v|
          expected_hours_sold = v[:sellable][:value]
          total_hours_billed = v[:billable][:value]
          begin
            ((total_hours_billed / expected_hours_sold) * 100).round(2)
          rescue
            0
          end
        end),
        yAxisID: 'y',
      }, {
        label: 'Sellable Ratio (%)',
        borderColor: COLORS[10],
        data: (key_metrics_by_period.values.map do |v|
          expected_hours_sold = v[:sellable][:value]
          non_sellable_hours = v[:non_sellable][:value]
          begin
            ((expected_hours_sold / (expected_hours_sold + non_sellable_hours)) * 100).round(2)
          rescue
            0
          end
        end),
        yAxisID: 'y',
        borderDash: [10,5]
      }, {
        label: 'Actual Hours Sold',
        backgroundColor: COLORS[8],
        data: (key_metrics_by_period.values.map do |v|
          v[:billable][:value]
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Non Billable',
        backgroundColor: COLORS[6],
        data: (key_metrics_by_period.values.map do |v|
          v[:non_billable][:value]
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Time Off',
        backgroundColor: COLORS[9],
        data: (key_metrics_by_period.values.map do |v|
          v[:time_off][:value]
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 0',
      }, {
        label: 'Sellable Hours',
        backgroundColor: COLORS[2],
        data: (key_metrics_by_period.values.map do |v|
          v[:sellable][:value]
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 1',
      }, {
        label: 'Non Sellable Hours',
        backgroundColor: COLORS[5],
        data: (key_metrics_by_period.values.map do |v|
          v[:non_sellable][:value]
        end),
        yAxisID: 'y1',
        type: 'bar',
        stack: 'Stack 1',
      }]
    }

    render(partial: "admin_user_key_metrics", locals: {
      skill_data: skill_data,
      utilization_data: utilization_data,

      all_gradations: all_gradations,
      current_gradation: current_gradation,
    })
  end
end