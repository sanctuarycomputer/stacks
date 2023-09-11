class Enterprise < ApplicationRecord
  has_one :qbo_account
  accepts_nested_attributes_for :qbo_account, allow_destroy: true

  VERTICAL_MATCHER = /\[(.+)\](.*)/

  # Is the programming business profitable?
  # Is the desk/rental business profitable?
  # Is the online course business profitable?
  # TODO: Setup Shopify <> QBO
  # TODO: Setup Deel <> QBO
  # TODO: Look into Patreon, Optix <> QBO

  def discover_verticals
    qbo_account.qbo_profit_and_loss_reports.reduce([]) do |acc, qbo_profit_and_loss_report|
      qbo_profit_and_loss_report.data["cash"]["rows"].each do |row|
        puts row[0]
        splat = /\[(.+)\](.*)/.match(row[0])
        acc |= [splat[1]] if splat.present?
      end
      acc
    end
  end
end
