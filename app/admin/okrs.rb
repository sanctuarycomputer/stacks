ActiveAdmin.register Okr do
  menu label: "OKRs", parent: "Money"
  config.filters = false
  config.paginate = false
  actions :index, :show, :new, :create, :edit, :update
  config.current_filters = false

  permit_params :name,
    :description,
    :operator,
    :datapoint,
    okr_periods_attributes: [
      :id,
      :okr_id,
      :starts_at,
      :ends_at,
      :target,
      :tolerance,
      :_destroy,
      :_edit,
      okr_period_studios_attributes: [
        :id,
        :okr_period_id,
        :studio_id,
        :_destroy,
        :_edit
      ]
    ]

  index download_links: false do
    column :name
    column :operator
    column :datapoint
    actions
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :name
      f.input :description
      f.input :operator
      f.input :datapoint

      f.has_many :okr_periods, heading: false, allow_destroy: true, new_record: 'Add a Period' do |a|
        a.input :starts_at, hint: "Leave blank for all time"
        a.input :ends_at, hint: "Leave blank for to mean until today"
        a.input :target
        a.input :tolerance

        a.has_many :okr_period_studios, heading: false, allow_destroy: true, new_record: 'Apply to Studio' do |b|
          b.input :studio
        end
      end
    end

    f.actions
  end


end
