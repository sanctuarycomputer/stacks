ActiveAdmin.register ProfitSharePass do
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false

  menu if: proc { current_admin_user.email == "hugh@sanctuary.computer" },
       label: "Profit Share",
       priority: 2

  actions :index, :show, :edit, :update
  permit_params :payroll_buffer_months, :efficiency_cap

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
    actions
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :payroll_buffer_months
      f.input :efficiency_cap
    end

    f.actions
  end
end
