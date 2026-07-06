class QboProfitAndLossLineItem < ApplicationRecord
  belongs_to :qbo_account
  belongs_to :qbo_profit_and_loss_report
end
