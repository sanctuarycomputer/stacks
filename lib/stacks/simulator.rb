class Stacks::Simulator
  EIGHT_HOURS_IN_SECONDS = 28800

  class << self
    def do(date = Date.today, opt_in = 0.3, hourly_rate = 160)
      start_of_month = date.beginning_of_month
      end_of_month = date.end_of_month

      studios = Studio.all
      admin_users = AdminUser.all
      non_billable_clients = [*studios.map(&:name), "garden3d"]

      assignments =
        ForecastAssignment
          .includes(forecast_project: :forecast_client)
          .includes(:forecast_person)
          .where('end_date >= ? AND start_date <= ?', start_of_month, end_of_month)

      total_hours_sold = assignments.reduce(0) do |acc, a|
        person = a.forecast_person
        project = a.forecast_project
        client = project.forecast_client
        user = admin_users.find{|au| au.email == person.email}
        next acc unless user.present?

        studio = studios.find{|s| person.roles.include?(s.name)}

        allocation =
          (allocation_during_month_in_seconds(start_of_month, a) / 60 / 60)

        is_time_off = (project.name == "Time Off" && client.nil?)
        is_non_billable = (client.present? && non_billable_clients.include?(client.name))

        next acc if is_time_off
        next acc if is_non_billable
        acc += allocation
      end

      total_hours_sold_in_scenario =
        (total_hours_sold - (total_hours_sold * opt_in)) + (total_hours_sold * opt_in * 0.8)

      # revenue = total_hours_sold * hourly_rate
      revenue_in_scenario = total_hours_sold_in_scenario * hourly_rate

      actuals = Stacks::Profitability.pull_actuals_for_month(start_of_month)
      cogs = (
        actuals[:gross_payroll] +
        actuals[:gross_benefits] +
        actuals[:gross_subcontractors] +
        actuals[:gross_expenses]
      )

      cogs_in_scenario =
        ((cogs - (cogs * opt_in)) * 1.2) + (cogs * opt_in)

      {
        #cogs: cogs,
        #total_hours_sold: total_hours_sold,
        #revenue: revenue,
        #margin: ((revenue - cogs) / revenue),
        #total_hours_sold_in_scenario: total_hours_sold,
        #revenue_in_scenario: revenue,
        margin_in_scenario: ((revenue_in_scenario - cogs_in_scenario) / revenue_in_scenario)
      }
    end

    def allocation_during_month_in_seconds(start_of_month, assignment)
      start_date = if assignment.start_date < start_of_month.beginning_of_month
          start_of_month.beginning_of_month
        else
          assignment.start_date
        end

      end_date = if assignment.end_date > start_of_month.end_of_month
          start_of_month.end_of_month
        else
          assignment.end_date
        end

      allocation = assignment.allocation
      days = if assignment.forecast_project["name"] == "Time Off" && allocation.nil?
          (start_date..end_date).select { |d| (1..5).include?(d.wday) }.size
        else
          (end_date - start_date).to_i + 1
        end

      # Time Off has a nil allocation
      per_day_allocation = (allocation.nil? ? EIGHT_HOURS_IN_SECONDS : allocation)
      (per_day_allocation * days).to_f
    end

  end
end
