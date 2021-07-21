ActiveAdmin.register AdminUser do
  menu if: proc { current_admin_user.is_payroll_manager? },
       label: "Team"
  actions :index, :show

  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false

  index do
    column :email
    column :skill_tree_level
    actions
  end

  show do
    data = {
      labels: [],
      datasets: [],
    }

    archived_reviews =
      resource.reviews.where.not(archived_at: nil).order("archived_at DESC").map do |r|
        {
          label: "#{r.archived_at.strftime("%B %d, %Y")}",
          chart: r.finalized_score_chart,
        }
      end

    if archived_reviews.any?
      sample = archived_reviews[0][:chart].keys
      label_mismatch = archived_reviews.any? { |r| r[:chart].keys != sample }
      if label_mismatch
        raise "Label mismatch. Please contact an admin."
      else
        data = archived_reviews.reduce({ labels: sample, datasets: [] }) do |data, review|
          data[:datasets] << {
            label: review[:label],
            data: review[:chart].values.map { |v| v[:sum] },
          }
          data
        end
      end
    end

    render(partial: "skill_radar_chart", locals: { data: data })
  end
end
