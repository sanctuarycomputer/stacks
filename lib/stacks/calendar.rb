class Stacks::Calendar
  class << self
    private

    # Helper method to create authorized Directory service
    def directory_service
      service = Google::Apis::AdminDirectoryV1::DirectoryService.new
      service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
        scope: [
          Google::Apis::AdminDirectoryV1::AUTH_ADMIN_DIRECTORY_USER_READONLY,
          Google::Apis::AdminDirectoryV1::AUTH_ADMIN_DIRECTORY_RESOURCE_CALENDAR_READONLY
        ]
      )
      service.authorization.sub = "hugh@sanctuary.computer"
      service.authorization.fetch_access_token!
      service
    end

    # Helper method to create authorized Calendar service (always uses admin account)
    def calendar_service
      service = Google::Apis::CalendarV3::CalendarService.new
      service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
        scope: Google::Apis::CalendarV3::AUTH_CALENDAR
      )
      service.authorization.sub = "hugh@sanctuary.computer"
      service.authorization.fetch_access_token!
      service
    end

    # Helper method to determine the appropriate user for calendar operations
    def calendar_user_for(event_or_email)
      if event_or_email.is_a?(Hash) && event_or_email[:user_email]&.start_with?("(Resource:")
        "hugh@sanctuary.computer"
      elsif event_or_email.is_a?(String) && event_or_email.start_with?("(Resource:")
        "hugh@sanctuary.computer"
      elsif event_or_email.is_a?(Hash)
        event_or_email[:user_email]
      else
        event_or_email
      end
    end

    # Helper method to fetch all users from the domain
    def fetch_all_users
      service = directory_service
      puts "Fetching all users in Google Workspace..."
      next_page_token = nil
      all_users = []
      begin
        response = service.list_users(domain: "sanctuary.computer", max_results: 500, page_token: next_page_token)
        all_users = [*all_users, *response.users]
        next_page_token = response.next_page_token
      end while next_page_token.present?
      puts "Found #{all_users.length} users"
      all_users
    end

    # Helper method to fetch all resources
    def fetch_all_resources
      directory_service.list_calendar_resources('my_customer', max_results: 500)
    end

    # Helper method to iterate through events in a calendar
    def each_event_in_calendar(calendar_service, calendar_id, options = {})
      events_page_token = nil
      begin
        params = {
          max_results: options[:max_results] || 2500,
          single_events: true,
          order_by: 'startTime',
          page_token: events_page_token
        }

        params[:time_min] = options[:time_min] if options[:time_min]
        params[:time_max] = options[:time_max] if options[:time_max]
        params[:q] = options[:query] if options[:query]
        params[:show_deleted] = options[:show_deleted] if options.key?(:show_deleted)

        events_response = calendar_service.list_events(calendar_id, **params)

        if events_response.items&.any?
          events_response.items.each do |event|
            yield event if block_given?
          end
        end

        events_page_token = events_response.next_page_token
      end while events_page_token.present?
    end

    # Helper method to iterate through all calendars in the workspace and yield matching events
    def search_all_calendars(options = {})
      query = options[:query]
      time_min = options[:time_min] || (DateTime.now - 1.year).rfc3339
      time_max = options[:time_max] || (DateTime.now + 1.year).rfc3339

      # First, search all user primary calendars by impersonating each user
      all_users = fetch_all_users
      puts "Found #{all_users.length} users to search"

      all_users.each_with_index do |user, index|
        begin
          puts "[#{index + 1}/#{all_users.length}] Checking primary calendar for: #{user.primary_email}"

          # Create service impersonating this user
          user_service = Google::Apis::CalendarV3::CalendarService.new
          user_service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
            scope: Google::Apis::CalendarV3::AUTH_CALENDAR
          )
          user_service.authorization.sub = user.primary_email
          user_service.authorization.fetch_access_token!

          # Search their primary calendar
          each_event_in_calendar(
            user_service,
            user.primary_email,
            time_min: time_min,
            time_max: time_max,
            query: query
          ) do |event|
            event_data = {
              event: event,
              user_email: user.primary_email,
              calendar_id: user.primary_email,
              event_id: event.id,
              recurring: event.recurring_event_id.present?,
              recurring_event_id: event.recurring_event_id,
              likely_orphaned: likely_orphaned?(event.organizer)
            }
            yield event, event_data if block_given?
          end

        rescue Google::Apis::ClientError => e
          puts "  Error accessing calendar for #{user.primary_email}: #{e.message}"
        rescue => e
          puts "  Unexpected error for #{user.primary_email}: #{e.message}"
        end
      end

      # Second, search all resource calendars
      begin
        all_resources = fetch_all_resources
        puts "Found #{all_resources.resources.length} resources to search" if all_resources&.resources

        all_resources&.resources&.each_with_index do |resource, index|
          begin
            puts "[R#{index + 1}/#{all_resources.resources.length}] Checking resource calendar: #{resource.resource_name}"

            admin_service = calendar_service
            each_event_in_calendar(
              admin_service,
              resource.resource_email,
              time_min: time_min,
              time_max: time_max,
              query: query
            ) do |event|
              event_data = {
                event: event,
                user_email: "(Resource: #{resource.resource_name})",
                calendar_id: resource.resource_email,
                event_id: event.id,
                recurring: event.recurring_event_id.present?,
                recurring_event_id: event.recurring_event_id,
                likely_orphaned: likely_orphaned?(event.organizer)
              }
              yield event, event_data if block_given?
            end

          rescue Google::Apis::ClientError => e
            puts "  Error accessing resource calendar #{resource.resource_email}: #{e.message}"
          rescue => e
            puts "  Unexpected error for resource #{resource.resource_email}: #{e.message}"
          end
        end
      rescue => e
        puts "Error fetching resource calendars: #{e.message}"
      end

      # Third, search admin-accessible calendars (transferred, shared calendars)
      begin
        admin_service = calendar_service
        calendar_list = admin_service.list_calendar_lists(max_results: 500)

        puts "Found #{calendar_list.items.length} admin-accessible calendars to search"

        calendar_list.items.each_with_index do |calendar, index|
          # Skip primary user calendars (we already searched those above)
          next if calendar.id.match?(/^[^@]+@sanctuary\.computer$/) && !calendar.summary&.start_with?("Transferred from")
          # Skip resource calendars (we already searched those above)
          next if calendar.id.include?("@resource.calendar.google.com")

          begin
            puts "[A#{index + 1}/#{calendar_list.items.length}] Checking admin calendar: #{calendar.summary || calendar.id}"

            each_event_in_calendar(
              admin_service,
              calendar.id,
              time_min: time_min,
              time_max: time_max,
              query: query
            ) do |event|
              # Determine user_email based on calendar type
              user_email = if calendar.summary&.start_with?("Transferred from")
                calendar.summary  # e.g. "Transferred from bre@sanctuary.computer"
              else
                calendar.id  # Shared or other calendar type
              end

              event_data = {
                event: event,
                user_email: user_email,
                calendar_id: calendar.id,
                event_id: event.id,
                recurring: event.recurring_event_id.present?,
                recurring_event_id: event.recurring_event_id,
                likely_orphaned: likely_orphaned?(event.organizer)
              }
              yield event, event_data if block_given?
            end

          rescue Google::Apis::ClientError => e
            puts "  Error accessing admin calendar #{calendar.id}: #{e.message}"
          rescue => e
            puts "  Unexpected error for admin calendar #{calendar.id}: #{e.message}"
          end
        end

      rescue => e
        puts "Error listing admin calendars: #{e.message}"
      end
    end

    # Helper method to group events by recurring series
    def group_events_by_recurring_series(matching_events, label)
      grouped_events = { single_events: [], recurring_groups: {} }

      matching_events.each do |event|
        if event[:recurring]
          # For recurring events, group by the base recurring event ID
          base_id = event[:recurring_event_id] || event[:event_id]

          # If we don't have a recurring_event_id, we need to fetch it
          if event[:recurring_event_id].nil?
            begin
              calendar_service = calendar_service
              full_event = calendar_service.get_event(event[:calendar_id], event[:event_id])
              base_id = full_event.recurring_event_id || event[:event_id]
              event[:recurring_event_id] = base_id
            rescue => e
              puts "Warning: Could not get recurring details for event #{event[:event_id]}: #{e.message}"
              grouped_events[:single_events] << event
              next
            end
          end

          grouped_events[:recurring_groups][base_id] ||= { root_event: nil, instances: [] }

          # If this event has no recurring_event_id, it IS the root event
          if event[:recurring_event_id].nil?
            grouped_events[:recurring_groups][base_id][:root_event] = event
          else
            grouped_events[:recurring_groups][base_id][:instances] << event
          end
        else
          grouped_events[:single_events] << event
        end
      end

      # For recurring groups without a root event, try to fetch the root
      grouped_events[:recurring_groups].each do |base_id, group|
        if group[:root_event].nil? && group[:instances].any?
          # Try to fetch the root event using the base_id and first instance's calendar info
          first_instance = group[:instances].first

          begin

            # Create service for the calendar owner
            user_calendar_service = Google::Apis::CalendarV3::CalendarService.new
            user_calendar_service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
              json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
              scope: Google::Apis::CalendarV3::AUTH_CALENDAR
            )
            user_calendar_service.authorization.sub = calendar_user_for(first_instance)
            user_calendar_service.authorization.fetch_access_token!

            # Try to get the root event
            root_event = user_calendar_service.get_event(first_instance[:calendar_id], base_id)

            # Add the root event to our results
            group[:root_event] = {
              event: root_event,
              user_email: first_instance[:user_email],
              calendar_id: first_instance[:calendar_id],
              event_id: root_event.id,
              recurring: false, # Root event doesn't have recurring_event_id
              recurring_event_id: nil,
              likely_orphaned: likely_orphaned?(root_event.organizer)
            }
            puts "Found missing root event for series: #{base_id}"
          rescue Google::Apis::ClientError => e
            if e.status_code == 404
              puts "Root event #{base_id} not found (may have been deleted)"
            else
              puts "Error fetching root event #{base_id}: #{e.message}"
            end
          rescue => e
            puts "Unexpected error fetching root event #{base_id}: #{e.message}"
          end
        end
      end

      # Print grouped results
      puts "\n" + "="*80
      puts "#{label.upcase}: #{matching_events.length}"
      puts "="*80

      if grouped_events[:recurring_groups].any?
        puts "\n#{label} recurring event series:"
        grouped_events[:recurring_groups].each do |base_id, group|
          root_event = group[:root_event]
          instances = group[:instances]
          total_count = (root_event ? 1 : 0) + instances.length

          puts "\n  Series: #{base_id} (#{total_count} events total)"
          puts "    Root: #{root_event ? 'Found' : 'Not found in search results'}"
          puts "    Instances: #{instances.length}"
          puts "    Base ID: #{base_id}"

          if root_event
            puts "    Root Calendar: #{root_event[:user_email]}"
          end
        end
      end

      if grouped_events[:single_events].any?
        puts "\n#{label} single events:"
        grouped_events[:single_events].each do |event|
          puts "\n  #{event[:event_id]}"
          puts "    Calendar: #{event[:user_email]}"
        end
      end

      grouped_events
    end

    public

    def find_event_by_name(event_name)
      matching_events = []

      puts "Searching all calendars in workspace for events named '#{event_name}'..."

      search_all_calendars(query: event_name) do |event, event_data|
        # Double-check name match (case-insensitive)
        if event.summary&.downcase&.include?(event_name.downcase)
          matching_events << event_data
        end
      end

      group_events_by_recurring_series(matching_events, "Events matching '#{event_name}'")
    end

    def likely_orphaned?(organizer)
      organizer.try(:email).try(:ends_with?, "@group.calendar.google.com") &&
      !["Sanctuary Meetings", "g3d Calendar"].include?(organizer.try(:display_name))
    end

    def cancel_recurring_event(root_event)
      # Cancel a recurring event series using the root event hash
      # root_event: hash with keys :user_email, :calendar_id, :event_id

      begin
        # Create calendar service for the appropriate user
        user_calendar_service = Google::Apis::CalendarV3::CalendarService.new
        user_calendar_service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
          json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
          scope: Google::Apis::CalendarV3::AUTH_CALENDAR
        )
        user_calendar_service.authorization.sub = calendar_user_for(root_event)
        user_calendar_service.authorization.fetch_access_token!

        # Cancel the entire recurring series
        user_calendar_service.delete_event(
          root_event[:calendar_id],
          root_event[:event_id],
          send_notifications: false  # Don't send email notifications
        )

        puts "✓ Successfully cancelled recurring series: #{root_event[:event_id]}"
        return { success: true, event_id: root_event[:event_id] }

      rescue Google::Apis::ClientError => e
        error_message = case e.status_code
        when 404
          "Event not found (may have been deleted)"
        when 403
          "Permission denied"
        when 410
          "Event has already been deleted"
        else
          "Google API error (#{e.status_code}): #{e.message}"
        end

        puts "✗ Failed to cancel recurring series #{root_event[:event_id]}: #{error_message}"
        return { success: false, error: error_message, event_id: root_event[:event_id] }

      rescue => e
        puts "✗ Unexpected error cancelling #{root_event[:event_id]}: #{e.message}"
        return { success: false, error: e.message, event_id: root_event[:event_id] }
      end
    end

    def find_orphaned_events
      matching_events = []

      puts "Searching all calendars in workspace for orphaned events..."

      search_all_calendars do |event, event_data|
        if event_data[:likely_orphaned]
          matching_events << event_data
        end
      end

      group_events_by_recurring_series(matching_events, "Orphaned events")
    end

    def cancel_orphaned_events
      orphans = find_orphaned_events
      orphans[:recurring_groups].each do |base_id, group|
        if group[:root_event]
          binding.pry
          next if ["Gardenxrs Monthly Meeting", "Future Chats"].include?(group[:root_event][:event].summary)
          cancel_recurring_event(group[:root_event])
        end
      end

    end
  end
end