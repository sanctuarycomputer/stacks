ActiveAdmin.register AssociatesAwardAgreement do
  config.filters = false
  config.paginate = false
  actions :index, :new, :create, :edit, :update, :destroy
  permit_params :admin_user_id,
    :started_at,
    :initial_unit_grant,
    :vesting_unit_increments,
    :vesting_periods,
    :vesting_period_type
  menu if: -> { current_admin_user.is_associate? }, parent: "Team"

  scope :active, default: true
  scope :all

  index download_links: false do
    column :admin_user
    column :started_at
    column :initial_unit_grant
    column :vesting_unit_increments
    column :vesting_periods
    column :vesting_period_type
    column :percentage do |resource|
      "#{(resource.percentage_of_pool_on(Date.today) * 100).round(2)}%"
    end
    actions
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :admin_user
      f.input :started_at
      f.input :initial_unit_grant
      f.input :vesting_unit_increments
      f.input :vesting_periods
      f.input :vesting_period_type
    end

    f.actions
  end
end
