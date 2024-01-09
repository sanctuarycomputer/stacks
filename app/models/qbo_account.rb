class QboAccount < ApplicationRecord
  belongs_to :enterprise
  has_one :qbo_token
  has_many :qbo_profit_and_loss_reports
  accepts_nested_attributes_for :qbo_token, allow_destroy: true

  # TODO as more enterprises come online, make this a column
  def started_at
     Date.new(2023, 1, 1)
  end

  def sync_all!
    sync_monthly_profit_and_loss_reports!
    sync_quarterly_profit_and_loss_reports!
    sync_yearly_profit_and_loss_reports!
  end

  def sync_monthly_profit_and_loss_reports!
    time = started_at
    while time < Date.today
      QboProfitAndLossReport.find_or_fetch_for_range(
        time.beginning_of_month,
        time.end_of_month,
        true,
        self
      )
      time = time.advance(months: 1)
    end
  end

  def sync_quarterly_profit_and_loss_reports!
    time = started_at
    while time < Date.today
      QboProfitAndLossReport.find_or_fetch_for_range(
        time.beginning_of_quarter,
        time.end_of_quarter,
        true,
        self
      )
      time = time.advance(months: 3)
    end
  end

  def sync_yearly_profit_and_loss_reports!
    time = started_at
    while time < Date.today
      QboProfitAndLossReport.find_or_fetch_for_range(
        time.beginning_of_year,
        time.end_of_year,
        true,
        self
      )
      time = time.advance(years: 1)
    end
  end

  def fetch_profit_and_loss_report_for_range(start_of_range, end_of_range, accounting_method = "Cash")
    qbo_access_token = make_and_refresh_qbo_access_token
    report_service = Quickbooks::Service::Reports.new
    report_service.company_id = realm_id
    report_service.access_token = qbo_access_token

    report_service.query("ProfitAndLoss", nil, {
      start_date: start_of_range.strftime("%Y-%m-%d"),
      end_date: end_of_range.strftime("%Y-%m-%d"),
      accounting_method: accounting_method
    })
  end

  def make_and_refresh_qbo_access_token
    oauth2_client = OAuth2::Client.new(client_id, client_secret, {
      site: "https://appcenter.intuit.com/connect/oauth2",
      authorize_url: "https://appcenter.intuit.com/connect/oauth2",
      token_url: "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer",
    })

    return nil if qbo_token.nil?

    access_token = OAuth2::AccessToken.new(
      oauth2_client,
      qbo_token.token,
      refresh_token: qbo_token.refresh_token
    )

    # Refresh the token if it's been longer than 10 minutes
    if ((DateTime.now.to_i - qbo_token.updated_at.to_i) / 60) >= 10
      access_token = access_token.refresh!
      qbo_token.update!(
        token: access_token.token,
        refresh_token: access_token.refresh_token
      )
    end

    access_token
  end
end
