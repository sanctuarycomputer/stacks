class Stacks::System
  class << self
    # The first date of the New Deal
    NEW_DEAL_START_AT = Date.new(2025, 6, 1)

    # This is the first date that every fulltimer at
    # garden3d was required to start accounting for
    # all of their hours in Harvest Forecast
    UTILIZATION_START_AT = Date.new(2021, 6, 1)

    # This is the first full month that we started recording
    # versions of NotionPage via PaperTrail in production
    NEW_BIZ_VERSION_HISTORY_START_AT = Date.new(2022, 7, 1)

    # Default targets for Project Trackers
    DEFAULT_PROJECT_TRACKER_TARGET_PROFIT_MARGIN = 50
    DEFAULT_PROJECT_TRACKER_TARGET_FREE_HOURS_PERCENT = 1

    EIGHT_HOURS_IN_SECONDS = 28800

    INVOICE_STATUSES_NEED_ACTION = [
      :not_made,
      :not_sent,
      :unpaid_overdue,
      :partially_paid_overdue,
    ]

    NOTION_ASSIGNMENTS_LINK =
      "https://www.notion.so/garden3d/cfc84dd4f3b34805ad6ecc881356235d?v=6bd09f13eaa04171859b3a668735766e"
    QBO_NOTES_FORECAST_MAPPING_BEARER =
      "automator:forecast_mapping:"
    QBO_NOTES_PAYMENT_TERM_BEARER =
      "automator:payment_term:"
    DEFAULT_PAYMENT_TERM = 15
    DEFAULT_CUSTOMER_MEMO = <<~HEREDOC
      EIN: 47-2941554
      W9: https://w9.sanctuary.computer

      WIRE:
      Sanctuary Computer Inc
      EIN: 47-2941554
      Rou #: 021000021
      Acc #: 685028396

      Chase Bank:
      405 Lexington Ave
      New York, NY 10174

      QUICKPAY:
      admin@sanctuarycomputer.com

      BILL.COM:
      admin@sanctuarycomputer.com
    HEREDOC

    def clients_served_since(start_of_period, end_of_period)
      assignments =
        ForecastAssignment
          .includes(forecast_project: :forecast_client)
        .where('end_date >= ? AND start_date <= ?', start_of_period, end_of_period)

      internal_client_names = Studio.all.map(&:name)

      clients =
        assignments
          .map{|a| a.forecast_project.forecast_client}.compact.uniq
          .reject{|c| internal_client_names.include?(c.name)}
    end
  end
end
