class Stacks::ForecastToRunnSyncer
  def initialize(project_tracker)
    raise "no_runn_project" if project_tracker.runn_projects.empty?
    @runn = Stacks::Runn.new
    @runn_people = @runn.get_people
    @runn_roles = @runn.get_roles
    @project_tracker = project_tracker
  end

  def sync!
    @project_tracker.forecast_projects.each do |fp|
      fp.forecast_assignments do |fa|
        runn_person = @runn_people.find{|rp| rp.email.downcase == fa.forecast_person.email.downcase}
        # TODO: Handle no runn_person present

        (fa.start_date..fa.end_date).each do |date|
          allocation_in_minutes = (fa.allocation_during_range_in_seconds(date, date, false) / 60)
          @runn.create_or_update_actual(
            date,
            allocation_in_minutes,
            runn_person.runn_id,
            @runn_project.runn_id

          )
        end
      end
    end
  end

  private
end
