module PayCycles
  class GenerateStubs
    class MissingRateError < StandardError; end
    class AcceptedStubMissingHoursError < StandardError; end

    attr_reader :pay_cycle

    def initialize(pay_cycle)
      @pay_cycle = pay_cycle
    end

    def self.call(pay_cycle)
      new(pay_cycle).call
    end

    def call
      raise NotImplementedError, "Implemented in Task 8+"
    end

    # Returns ForecastAssignments overlapping this cycle whose project's
    # forecast_client.is_internal? AND whose forecast_client is mapped to
    # this cycle's enterprise.
    def qualifying_assignments
      internal_names = ForecastClient::INTERNAL_CLIENTS

      ForecastAssignment
        .joins(forecast_project: :forecast_client)
        .joins("INNER JOIN enterprise_forecast_clients efc ON efc.forecast_client_id = forecast_clients.forecast_id")
        .where(forecast_clients: { name: internal_names })
        .where("efc.enterprise_id = ?", pay_cycle.enterprise_id)
        .where("forecast_assignments.start_date <= ?", pay_cycle.ends_at)
        .where("forecast_assignments.end_date >= ?", pay_cycle.starts_at)
        .includes(:forecast_person, forecast_project: :forecast_client)
    end
  end
end
