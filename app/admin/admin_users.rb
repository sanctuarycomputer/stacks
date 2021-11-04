ActiveAdmin.register AdminUser do
  permit_params :show_skill_tree_data, :opt_out_of_dei_data_entry, :old_skill_tree_level, racial_background_ids: [], cultural_background_ids: [], gender_identity_ids: [], community_ids: []
  config.current_filters = false
  menu label: "Team"
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
      resource.show_skill_tree_data? ? resource.skill_tree_level_without_salary : "Private"
    end
    column :has_dei_response? do |resource|
      !resource.should_nag_for_dei_data?
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
    render(partial: "docs_linkout")

    f.semantic_errors
    f.inputs(class: "admin_inputs") do
      f.input :show_skill_tree_data, label: "Make my Skill Tree Data public"
    end

    render(partial: "add_more_dei_categories")
    f.inputs(id: "dei_admin_inputs") do
      f.input :racial_backgrounds,
        as: :check_boxes,
        label: "How do you describe your racial background?",
        collection: (RacialBackground.order(opt_out: :asc).all.map do |e|
          [
            "#{e.name} #{e.description.blank? ? "" : "(" + e.description + ")"}",
            e.id,
            { "data-opt-out" => e.opt_out, onclick: "didClickCheckbox(this)" },
          ]
        end)
      f.input :cultural_backgrounds,
        as: :check_boxes,
        label: "How do you describe your cultural background?",
        collection: (CulturalBackground.order(opt_out: :asc).all.map do |e|
          [e.name, e.id, { "data-opt-out" => e.opt_out, onclick: "didClickCheckbox(this)" }]
        end)
      f.input :gender_identities,
        as: :check_boxes,
        label: "How do you describe your gender identity?",
        collection: (GenderIdentity.order(opt_out: :asc).all.map do |gi|
          [gi.name, gi.id, { "data-opt-out" => gi.opt_out, onclick: "didClickCheckbox(this)" }]
        end)
      f.input :communities,
        as: :check_boxes,
        label: "Are you a part of any other communities?",
        collection: Community.all.map { |c| [c.name, c.id] }
    end

    script (<<-JS
        function didClickCheckbox(el) {
        window.el = el;
          if (el.dataset.optOut === 'true') {
            Array.from(el.parentElement.parentElement.parentElement.getElementsByTagName('input')).forEach(e => {
              if (e !== el) e.checked = 0;
            });
          } else if (el.dataset.optOut === 'false') {
            Array.from(el.parentElement.parentElement.parentElement.getElementsByTagName('input')).forEach(e => {
              if (e.dataset.optOut === 'true') e.checked = 0;
            });
          }
        }
      JS
).html_safe

    if current_admin_user.is_payroll_manager?
      f.inputs(class: "admin_inputs") do
        f.input :old_skill_tree_level, as: :select, collection: AdminUser.old_skill_tree_levels.keys
      end
    end

    f.actions
  end
end
