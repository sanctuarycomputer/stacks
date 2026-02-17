ActiveAdmin.register AdminUser do
  permit_params :show_skill_tree_data,
    :ignore,
    :old_skill_tree_level,
    :profit_share_notes,
    full_time_periods_attributes: [
      :id,
      :admin_user_id,
      :started_at,
      :ended_at,
      :considered_temporary,
      :contributor_type,
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
  menu label: "Everybody", parent: "Team", priority: 1
  actions :index, :show, :edit, :update

  scope :active, default: true
  scope :inactive
  scope :admin
  scope :ignored
  scope :associates
  scope :all

  config.filters = false
  config.current_filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false

  action_item :toggle_admin, only: :show, if: proc { current_admin_user.is_admin? } do
    if resource.is_admin?
      link_to "Demote Admin", demote_admin_user_admin_admin_user_path(resource), method: :post
    else
      link_to "Promote Admin", promote_admin_user_admin_admin_user_path(resource), method: :post
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

  index download_links: false do
    column :team_member do |resource|
      resource
    end
    column :forecast_person do |resource|
      resource.forecast_person
    end
    if current_admin_user.is_hugh?
      column :last_month_utilization do |resource|
        latest_key_metrics = resource.latest_key_metrics
        should_have_sold_hours = latest_key_metrics[:sellable][:value].present? && latest_key_metrics[:sellable][:value] > 0
        next nil unless should_have_sold_hours



        surplus = (latest_key_metrics[:billable][:value] - latest_key_metrics[:sellable][:value]).round(2)
        extreme = surplus.abs > 20
        health = surplus >= 0 ? (extreme ? :exceptional : :healthy) : (extreme ? :failing : :at_risk)
        bearer = surplus >= 0 ? "+" : "-"

        div([
          span(class: "pill #{health}") do
            span("#{health.to_s.humanize}")
            span(class: "split natural") do
              "#{bearer}#{surplus.abs} hrs"
            end
          end
        ])
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

    render(partial: "show", locals: { resource: resource })
  end

  form do |f|
    f.semantic_errors

    if current_admin_user.is_admin?
      f.inputs(class: "admin_inputs") do
        f.input :ignore, hint: "Check this box if this account is a dummy email address, bot or duplicate."
        f.input :old_skill_tree_level,
          as: :select, collection: AdminUser.old_skill_tree_levels.keys,
          label: "Starting skill tree level"
        f.input :profit_share_notes

        f.has_many :full_time_periods, heading: false, allow_destroy: true do |a|
          a.semantic_errors

          a.input :started_at, hint: "The date this employment period started."
          a.input :ended_at, hint: "Leave blank until the nature of employment changes (termination or a move to 4-day work week, which requires an additional employment period to be added here)."
          a.input :considered_temporary, hint: "Check this box if this period was considered temporary (like an internship)."
          a.input :contributor_type,
            include_blank: false,
            as: :select,
            hint: "Use Variable hours for a contractor who's billing us hourly. Otherwise, they should be Four or Five day contributors."
          a.input :expected_utilization, hint: "Ignored when Contributor Type is `Variable Hours`. ICs should be 0.8, Support Team members are 0.0. Studio Coordinators depend on the size of the studio coordination group."
        end

script (<<-JS
  function greyAndZeroOutExpectedUtilizationFieldForVariableHoursContributorType(el) {
    var expectedUtilizationInput =
      Array.from(el.parentElement.parentElement.querySelectorAll('input')).find(i => i.id.endsWith("_expected_utilization"))
    if (el.value === "variable_hours") {
      expectedUtilizationInput.value = 0;
      expectedUtilizationInput.disabled = true;
    } else {
      expectedUtilizationInput.disabled = false;
    }
  }
  const contributorTypeSelects =
    Array.from(document.querySelectorAll('select')).filter(s => s.id.endsWith("_contributor_type"));
  contributorTypeSelects.forEach(el => {
    greyAndZeroOutExpectedUtilizationFieldForVariableHoursContributorType(el);
    el.addEventListener('change', function() {
      greyAndZeroOutExpectedUtilizationFieldForVariableHoursContributorType(el);
    });
  })
JS
).html_safe

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
