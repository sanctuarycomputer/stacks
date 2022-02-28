class Stacks::Invoicing
  class << self
    def generate_invoices_for_work_during_range(start_of_range, end_of_range)
      invoice_month = start_of_range.strftime("%B %Y")

      studios = Studio.all
      assignments =
        ForecastAssignment
          .includes(:forecast_person)
          .includes(forecast_project: :forecast_client)
          .where('end_date >= ? AND start_date <= ?', start_of_range, end_of_range)

      assignments_by_client = assignments.reduce({}) do |acc, a|
        person = a.forecast_person
        project = a.forecast_project
        client = a.forecast_project.forecast_client

        # Time Off in Forecast
        next acc if client.nil?
        # Skip Internal Projects
        next acc if [*studios.map(&:name), 'garden3d'].include?(client.name)
        acc[client.forecast_id] = acc[client.forecast_id] || {lines: {}, forecast_projects: []}

        # Track the forecast_project ids
        acc[client.forecast_id][:forecast_projects] << project.forecast_id
        acc[client.forecast_id][:forecast_projects].uniq

        # Track the forecast_project ids
        line_descriptor =
          "#{project.code} #{project.name} (#{invoice_month}) #{person.first_name} #{person.last_name}"
        acc[client.forecast_id][:lines][line_descriptor] =
          acc[client.forecast_id][:lines][line_descriptor] || {
            service:
              studios.find{|s| person.roles.include?(s.name)}.try(:accounting_prefix) || "Services",
            allocation: 0,
            hourly_rate: project.hourly_rate
          }
        acc[client.forecast_id][:lines][line_descriptor][:allocation] +=
          a.allocation_during_range_in_hours(start_of_range, end_of_range)

        acc
      end

      binding.pry
    end

  end
end
