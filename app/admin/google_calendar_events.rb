ActiveAdmin.register GoogleCalendarEvent do
  menu false
  config.filters = false
  config.paginate = true
  actions :index, :show
  config.sort_order = "start_desc"

  scope :confirmed, default: true
  scope :cancelled
  scope :all

  index download_links: false, title: "Calendars" do
    column :summary
    column :past?
    column :attendance_count do |resource|
      resource.google_meet_attendance_records.count
    end
    column :attendance_rate
    column :start
    actions
  end

  show do
    render(partial: "show", locals: {
    })
  end
end
