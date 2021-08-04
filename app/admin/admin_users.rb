ActiveAdmin.register AdminUser do
  permit_params :show_skill_tree_data
  config.current_filters = false
  menu if: proc { current_admin_user.is_payroll_manager? },
       label: "Team"
  actions :index, :show, :edit, :update
  scope :active, default: true
  scope :archived

  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false

  action_item :archive, only: :show, if: proc { current_admin_user.is_payroll_manager? } do
    if resource.archived_at.present?
      link_to "Unarchive", unarchive_admin_user_admin_admin_user_path(resource), method: :post
    else
      link_to "Archive", archive_admin_user_admin_admin_user_path(resource), method: :post
    end
  end

  member_action :archive_admin_user, method: :post do
    resource.update!(archived_at: DateTime.now)
    redirect_to admin_admin_user_path(resource), notice: "Archived!"
  end

  member_action :unarchive_admin_user, method: :post do
    resource.update!(archived_at: nil)
    redirect_to admin_admin_user_path(resource), notice: "Archive reverted!"
  end

  index download_links: false do
    column :team_member do |resource|
      resource
    end
    column :skill_tree_level do |resource|
      resource.show_skill_tree_data? ? resource.skill_tree_level : "Private"
    end
    actions
  end

  show do
    COLORS = [
      "#1F78FF",
      "#ffa500",
      "#414141",
      "#26bd50",
      "#7B4EFA",
      "#FF6961",
      "5E6469",
    ]

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
            borderColor: COLORS[archived_reviews.index(review)],
          }
          data
        end
      end
    end

    render(partial: "skill_radar_chart", locals: { data: data })
  end

  form do |f|
    f.semantic_errors
    f.inputs(class: "admin_inputs") do
      f.input :show_skill_tree_data, label: "Make my Skill Tree Data public"
    end
    f.actions
  end
end
