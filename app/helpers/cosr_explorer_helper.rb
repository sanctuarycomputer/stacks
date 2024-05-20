module CosrExplorerHelper
  # Takes the COSR data format emitted from ProjectTracker.cost_of_services_rendered,
  # and transforms it into the format necessary for use in the COSR Explorer template.
  def build_monthly_rollup(cosr_data)
    forecast_person_ids = []
    studio_ids = []

    monthly_studio_rollups = cosr_data.reduce({}) do |acc, tuple|
      date, studio_datas = tuple
      month_start = date.beginning_of_month
      acc[month_start] ||= {}

      studio_datas.each do |studio_id, studio_data|
        studio_rollup = acc[month_start][studio_id] ||= {
          total_cost: 0,
          assignment_rollups: {}
        }

        studio_rollup[:total_cost] += studio_data[:total_cost]
        studio_ids << studio_id

        studio_data[:assignment_costs].each do |assignment_cost|
          person_id, hourly_cost, hours, effective_date = assignment_cost.fetch_values(
            :forecast_person_id,
            :hourly_cost,
            :hours,
            :effective_date
          )

          forecast_person_ids << person_id
          composite_key = "#{person_id}-#{hourly_cost}"

          assignment_rollup = studio_rollup[:assignment_rollups][composite_key] ||= {
            forecast_person_id: person_id,
            hours: 0,
            hourly_cost: hourly_cost,
            total_cost: 0,
            start_date: effective_date,
            end_date: effective_date
          }

          assignment_rollup[:hours] += hours
          assignment_rollup[:total_cost] += hourly_cost * hours
          assignment_rollup[:start_date] = [assignment_rollup[:start_date], date].min
          assignment_rollup[:end_date] = [assignment_rollup[:end_date], date].max
        end
      end

      acc
    end

    [monthly_studio_rollups, forecast_person_ids.uniq, studio_ids.uniq]
  end

  def format_date_range(assignment_rollup)
    start_date, end_date = assignment_rollup.fetch_values(:start_date, :end_date)

    if start_date == end_date
      format_date(start_date)
    else
      "#{format_date(start_date)} to #{format_date(end_date)}"
    end
  end

  private

  def format_date(date)
    date.strftime("%-m/%-d")
  end
end
