ActiveAdmin.register ProfitSharePass do
  menu label: "Profit Share", parent: "Money"
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false

  actions :index, :show, :edit, :update
  permit_params :payroll_buffer_months, :efficiency_cap, :internals_budget_multiplier

  action_item :finalize, only: :edit, if: proc { current_admin_user.is_admin? } do
    if resource.finalized?
      link_to "Undo Finalize", unfinalize_admin_profit_share_pass_path(resource), method: :post
    else
      link_to "Finalize", finalize_admin_profit_share_pass_path(resource), method: :post
    end
  end

  member_action :finalize, method: :post do
    resource.finalize!(resource.make_scenario)
    redirect_to edit_admin_profit_share_pass_path(resource), notice: "Archived!"
  end

  member_action :unfinalize, method: :post do
    resource.update!(snapshot: nil)
    redirect_to edit_admin_profit_share_pass_path(resource), notice: "Unfinalized!"
  end

  show do
    render 'show', { profit_share_pass: profit_share_pass }
  end

  index download_links: false do
    column :year do |resource|
      resource.created_at.year
    end
    column :status do |resource|
      if resource.is_projection?
        span("Projection", class: "pill waiting")
      else
        span("Finalized", class: "pill complete")
      end
    end
    column :finalized_psu_value do |resource|
      if resource.is_projection?
        "Not Finalized"
      else
        "$#{resource.make_scenario.actual_value_per_psu.round(2)}"
      end
    end
    actions
  end

  form do |f|
    unless resource.finalized?
      f.inputs(class: "admin_inputs") do
        f.input :payroll_buffer_months
        f.input :efficiency_cap
        f.input :internals_budget_multiplier
      end
      f.actions
    end
  end
end
