ActiveAdmin.register AdminUser do
  menu false
  actions :index, :show

  index do
    selectable_column
    id_column
    column :email
    column :current_sign_in_at
    column :sign_in_count
    column :created_at
    actions
  end

  show do
    data = {
      labels: [],
      datasets: []
    }

    archived_reviews =
      resource.reviews.where.not(archived_at: nil).order("archived_at DESC").map do |r|
        {
          label: "#{r.archived_at.strftime("%B %d, %Y")}",
          chart: r.finalized_score_chart
        }
      end

    if archived_reviews.any?
      sample = archived_reviews[0][:chart].keys
      label_mismatch = archived_reviews.any?{|r| r[:chart].keys != sample}
      if label_mismatch
        raise "Label mismatch. Please contact an admin."
      else
        data = archived_reviews.reduce({ labels: sample, datasets: [] }) do |data, review|
          data[:datasets] << {
            label: review[:label],
            data: review[:chart].values.map{|v| v[:sum]}
          }
          data
        end
      end
    end

    render(partial: 'skill_radar_chart', locals: { data: data })
  end

  filter :email
  filter :current_sign_in_at
  filter :sign_in_count
  filter :created_at

  form do |f|
    f.inputs do
      f.input :email
      f.input :password
      f.input :password_confirmation
    end
    f.actions
  end
end
