ActiveAdmin.register KeyMeeting do
  menu label: "Key Meetings", parent: "Team"
  config.filters = false
  config.paginate = false
  permit_params :name,
    :matcher,
    studio_key_meetings_attributes: [
      :id,
      :studio_id,
      :key_meeting_id,
      :_destroy,
      :_edit
    ]
  actions :index, :new, :create, :edit, :update

  index download_links: false, title: "Key Meetings" do
    column :name
    column :studios
    column :events do |resource|
      link_to "View Events", admin_google_calendar_events_path({
        "q[summary_equals]" => resource.name,
        "order" => "start_desc"
      })
    end
    actions
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :name

      f.has_many :studio_key_meetings, heading: false, allow_destroy: true, new_record: 'Add a Studio' do |a|
        a.input :studio
      end
    end

    f.actions
  end
end
