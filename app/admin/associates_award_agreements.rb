ActiveAdmin.register AssociatesAwardAgreement do
  config.filters = false
  config.paginate = false
  actions :index, :show, :new, :create, :edit, :update, :destroy
  permit_params :admin_user_id,
    :started_at,
    :total_awardable_units,
    :installment_amount,
    :contract_url
  menu label: "Associates", if: -> { current_admin_user.is_associate? }, parent: "Team"

  scope :active, default: true
  scope :all

  index download_links: false do
    column :admin_user
    column :started_at
    column :total_awardable_units
    column :installment_amount

    actions
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :admin_user, collection: AdminUser.active.order(:email), input_html: { disabled: !f.object.new_record? }
      f.input :started_at
      f.input :total_awardable_units
      f.input :installment_amount
      f.input :contract_url
    end

    f.actions
  end

  show do
    vs = resource.vesting_schedule

    vesting_schedule_data = {
      labels: vs[:timeline].map{|t| t[:starts_at].strftime("%B, %Y")},
      datasets: [{
        label: 'Vested Units',
        borderColor: Stacks::Utils::COLORS[0],
        type: 'line',
        data: (vs[:timeline].map do |t|
          t[:net_vested]
        end)
      }, {
        label: 'Total Awardable Units',
        borderColor: Stacks::Utils::COLORS[2],
        type: 'line',
        data: (vs[:timeline].map do |t|
          vs[:total_awardable_units]
        end),
        borderDash: [10,5],
        pointRadius: 0
      }, {
        label: 'Floor (10%)',
        borderColor: Stacks::Utils::COLORS[1],
        type: 'line',
        data: (vs[:timeline].map do |t|
          vs[:floor_units]
        end),
        borderDash: [10,5],
        pointRadius: 0
      }]
    }

    render(partial: "show", locals: {
      vested_today: resource.vested_units_on(Date.today, vs),
      percentage_of_pool_today: resource.percentage_of_pool_on(Date.today, vs),
      vesting_schedule: vs,
      vesting_schedule_data: vesting_schedule_data,
    })
  end
end
