class Stacks::Availability
  class << self
    def notion
      @_notion ||= Stacks::Notion.new
    end

    def load_allocations_from_notion
      results = []
      next_cursor = nil
      loop do
        response = notion.query_database("cfc84dd4f3b34805ad6ecc881356235d", next_cursor)
        results = [*results, *response["results"]]
        next_cursor = response["next_cursor"]
        break if next_cursor.nil?
      end

      errors = []
      allocations = results.reduce({}) do |acc, a|
        email =
          (a.dig("properties", "Assign", "people").try(:first) || {}).dig("person", "email")

        starts_at = a.dig("properties", "Date", "date", "start")
        ends_at = a.dig("properties", "Date", "date", "end")
        if (starts_at.nil? || ends_at.nil?)
          errors << { error: :dates, url: a["url"], email: email }
          next acc
        end

        starts_at = Date.parse(starts_at)
        ends_at = Date.parse(ends_at)
        next acc if ends_at < Date.today

        if email.nil?
          errors << { error: :email, url: a["url"] }
          next acc
        end

        allocation = a.dig("properties", "Role Capacity", "number")
        if allocation.nil?
          errors << { error: :allocation, url: a["url"], email: email } if allocation.nil?
          next acc
        end

        acc[email] = acc[email] || []
        acc[email] << {
          start: starts_at,
          end: ends_at,
          allocation: allocation,
          url: a["url"],
          studios: Stacks::Utils.studios_for_email(email)
        }
        acc
      end

      # Ensure all AdminUser are included
      AdminUser.active.each do |a|
        allocations[a.email] = allocations[a.email] || []
      end

      [allocations, errors]
    end

    def discover_changes!(all_allocations)
      diffs = []
      last_allocations = allocations_on_date(all_allocations)
      date = Date.today
      loop do
        date += 1.day
        allocations = allocations_on_date(all_allocations, date)
        diff = Stacks::Utils.hash_diff(last_allocations, allocations)
        unless diff.empty?
          changes = diff.keys.reduce({}) do |acc, email|
            acc[email] = [last_allocations[email], allocations[email]]
            acc
          end
          diffs << [date, changes]
        end
        last_allocations = allocations
        break if (date - Date.today) > 365
      end

      diffs
    end

    def allocations_on_date(all_allocations, date = Date.today)
      all_allocations.reduce({}) do |acc, d|
        acc[d[0]] =
          ((d[1].select{|a| a[:start] <= date && a[:end] >= date} || []).map do |a|
            a[:allocation]
          end.reduce(:+) || 0)
        acc
      end
    end
  end
end
