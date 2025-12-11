class Stacks::System
  class << self
    # The first date of the New Deal
    NEW_DEAL_START_AT = Date.new(2025, 6, 1)

    # This is the first date that every fulltimer at
    # garden3d was required to start accounting for
    # all of their hours in Harvest Forecast
    UTILIZATION_START_AT = Date.new(2021, 6, 1)

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

      assignments.map{|a| a.forecast_project.forecast_client}.compact.uniq
    end

    def sync_founder_trueups!
      working_date = NEW_DEAL_START_AT.clone
      loop do
        break if working_date.month == Date.today.month

        invoice_pass = InvoicePass.includes(invoice_trackers: :contributor_payouts).where(start_of_month: working_date).first
        raise "No invoice pass found for #{working_date}" unless invoice_pass.present?

        contributor_payouts_by_contributor = invoice_pass.invoice_trackers.reduce({}) do |acc, invoice_tracker|
          invoice_tracker.contributor_payouts.each do |contributor_payout|
            acc[contributor_payout.forecast_person] ||= { payouts: [], amount: 0 }
            acc[contributor_payout.forecast_person][:payouts] << contributor_payout
            acc[contributor_payout.forecast_person][:amount] += contributor_payout.amount
          end
          acc
        end

        highest_contributor, highest_contributor_data = contributor_payouts_by_contributor.max_by{|k, v| v[:amount]}

        hugh = ForecastPerson.find_by(email: "hugh@sanctuary.computer").contributor
        trueup = Trueup.find_or_initialize_by(invoice_pass: invoice_pass, contributor: hugh)

        founder_trueup_amount = highest_contributor_data[:amount] - contributor_payouts_by_contributor[hugh][:amount]

        trueup.update!(
          amount: founder_trueup_amount,
          description: <<~HEREDOC
          # Trueup for #{working_date.strftime("%B %Y")}
          - **Highest Paid Contributor:** #{highest_contributor.email}
          - **Amount:** #{ActionController::Base.helpers.number_to_currency(highest_contributor_data[:amount])}
          - **Trueup Amount:** #{ActionController::Base.helpers.number_to_currency(founder_trueup_amount)}
          HEREDOC
        )

        working_date = working_date.advance(months: 1)
      end
    end
  end
end
