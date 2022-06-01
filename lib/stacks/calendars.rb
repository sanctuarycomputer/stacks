class Stacks::Calendars
  class << self
    def sync_all!
      service = Google::Apis::CalendarV3::CalendarService.new
      service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
        scope: Google::Apis::CalendarV3::AUTH_CALENDAR
      )
      service.authorization.sub = "hugh@sanctuary.computer"
      service.authorization.fetch_access_token!

      lists = service.list_calendar_lists
      ActiveRecord::Base.transaction do
        calendars = [
          "3qg4musj7ch2ndnlooohk6bahfb8kpnj@import.calendar.google.com", # Justworks Calendar
          "c_ost5qq25j8grdtamt9tu82jl7c@group.calendar.google.com", # Clockwise g3d
          "sanctuary.computer_gbrhi5ntv010b4878hcjg4vrks@group.calendar.google.com", # g3d calendar
        ].map do |google_id|
          cal = GoogleCalendar.where(google_id: google_id).first_or_create
          cal_detail = lists.items.find do |c|
            c.id === google_id
          end
          cal.update!(
            name: cal_detail.try(:summary_override) || cal_detail.summary
          )
          sync_events!(service, cal)
        end

        sync_attendance!
      end
    end

    def sync_attendance!
      service = Google::Apis::AdminReportsV1::ReportsService.new
      service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
        scope: Google::Apis::AdminReportsV1::AUTH_ADMIN_REPORTS_AUDIT_READONLY
      )
      service.authorization.sub = "hugh@sanctuary.computer"
      service.authorization.fetch_access_token!

      next_page_token = nil

      begin
        response = service.list_activities("all", "meet", {
          event_name: "call_ended",
          page_token: next_page_token
        })

        data = response.items.map do |a|
          id_type =
            a.events.first.parameters
             .find{|a| a.name === "identifier_type"}.try(:value)
          participant_id =
            a.events.first.parameters
             .find{|p| p.name == "identifier"}.try(:value)
          calendar_event_id =
            a.events.first.parameters
             .find{|p| p.name == "calendar_event_id"}.try(:value)
          endpoint_id =
            a.events.first.parameters
             .find{|p| p.name == "endpoint_id"}.try(:value)
          next nil if id_type != "email_address"
          next nil unless calendar_event_id.present?
          {
            google_endpoint_id: endpoint_id,
            participant_id: participant_id,
            google_calendar_event_id: calendar_event_id,
          }
        end.compact

        GoogleMeetAttendanceRecord.upsert_all(
          data,
          unique_by: :google_endpoint_id
        )
        next_page_token = response.next_page_token
      rescue => e
        raise e
      end while (response.next_page_token.present?)
    end

    def sync_events!(service, calendar)
      next_page_token = nil

      begin
        if calendar.sync_token.nil?
          response = service.list_events(calendar.google_id, {
            single_events: true,
            time_max: DateTime.now.utc.strftime("%FT%TZ"),
            max_results: 2500,
            page_token: next_page_token
          })
        else
          response = service.list_events(calendar.google_id,
            sync_token: calendar.sync_token,
            page_token: next_page_token
          )
        end
        data = response.items.map do |e|
          {
            google_id: e.id,
            google_calendar_id: calendar.id,
            start: (e.start ?
              (e.start.date_time || e.start.date.to_datetime) :
              nil
            ),
            end: (e.end ?
              (e.end.date_time || e.end.date.to_datetime) :
              nil
            ),
            html_link: e.html_link,
            status: e.status,
            description: e.description,
            summary: e.summary,
            recurrence: e.recurrence,
            recurring_event_id: e.recurring_event_id
          }
        end
        if data.any?
          GoogleCalendarEvent.upsert_all(
            data,
            unique_by: :google_id
          )
        end
        next_page_token = response.next_page_token
      rescue => e
        raise e
      end while (response.next_sync_token.nil?)

      calendar.update_attributes(sync_token: response.next_sync_token)
    end
  end
end
