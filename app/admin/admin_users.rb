ActiveAdmin.register AdminUser do
  permit_params :show_skill_tree_data,
    :opt_out_of_dei_data_entry,
    :old_skill_tree_level,
    :profit_share_notes,
    racial_background_ids: [],
    cultural_background_ids: [],
    gender_identity_ids: [],
    community_ids: [],
    full_time_periods_attributes: [
      :id,
      :admin_user_id,
      :started_at,
      :ended_at,
      :multiplier,
      :expected_utilization,
      :_edit,
      :_destroy
    ],
    gifted_profit_shares_attributes: [
      :id,
      :admin_user_id,
      :reason,
      :amount,
      :_edit,
      :_destroy
    ],
    pre_profit_share_purchases_attributes: [
      :id,
      :admin_user_id,
      :note,
      :amount,
      :purchased_at,
      :_edit,
      :_destroy
    ]
  config.current_filters = false
  menu label: "Everybody", parent: "Team", priority: 1
  actions :index, :show, :edit, :update
  scope :active, default: true
  scope :archived
  scope :admin
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false

  action_item :archive, only: :show, if: proc { current_admin_user.is_admin? } do
    if resource.archived_at.present?
      link_to "Unarchive", unarchive_admin_user_admin_admin_user_path(resource), method: :post
    else
      link_to "Archive", archive_admin_user_admin_admin_user_path(resource), method: :post
    end
  end

  action_item :toggle_admin, only: :show, if: proc { current_admin_user.is_admin? } do
    if resource.is_admin?
      link_to "Demote as Admin", demote_admin_user_admin_admin_user_path(resource), method: :post
    else
      link_to "Promote to Admin", promote_admin_user_admin_admin_user_path(resource), method: :post
    end
  end

  member_action :demote_admin_user, method: :post do
    resource.update!(roles: [])
    redirect_to admin_admin_user_path(resource), notice: "Success!"
  end

  member_action :promote_admin_user, method: :post do
    resource.update!(roles: ["admin"])
    redirect_to admin_admin_user_path(resource), notice: "Success!"
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
    column :is_admin? do |resource|
      resource.is_admin?
    end
    column :has_dei_response? do |resource|
      !resource.should_nag_for_dei_data?
    end
    column :projected_psu_by_eoy do |resource|
      resource.projected_psu_by_eoy
    end
    if current_admin_user.is_admin?
      column :expected_utilization do |resource|
        "#{(resource.expected_utilization * 100)}%"
      end
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
      labels =
        archived_reviews.reduce([]) {|acc, r| [*acc, *r[:chart].keys] }.uniq
      data = archived_reviews.reduce({ labels: labels, datasets: [] }) do |data, review|
        data[:datasets] << {
          label: review[:label],
          data: data[:labels].map{|l| review[:chart][l] && review[:chart][l][:sum] || 0 },
          borderColor: COLORS[archived_reviews.index(review)],
        }
        data
      end
    end

    render(partial: "show", locals: { data: data })
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

    if current_admin_user.is_admin?
      hr
      h1 "Admin Only"
      f.inputs(class: "admin_inputs") do
        f.input :old_skill_tree_level,
          as: :select, collection: AdminUser.old_skill_tree_levels.keys,
          label: "Starting skill tree level"
        f.input :profit_share_notes

        f.has_many :full_time_periods, heading: false, allow_destroy: true do |a|
          a.input :started_at, hint: "The date this employment period started"
          a.input :ended_at, hint: "Leave blank until the nature of employment changes (termination or a move to 4-day work week, which requires an additional employment period to be added here)"
          a.input :multiplier, label: "PSU earn rate", hint: "The rate that this employee earns PSU each month (4-day workers earn PSU at a rate of 0.8 per month)"
          a.input :expected_utilization, hint: "ICs should be 0.8, Support Team members are 0.0. Studio Coordinators depend on the size of the studio coordination group."
        end

        f.has_many :gifted_profit_shares, heading: false, allow_destroy: true do |a|
          a.input :amount
          a.input :reason
        end

        f.has_many :pre_profit_share_purchases, heading: false, allow_destroy: true do |a|
          a.input :amount
          a.input :note
          a.input :purchased_at
        end
      end
    end

    f.actions
  end
end
