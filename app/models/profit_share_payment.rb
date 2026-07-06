class ProfitSharePayment < ApplicationRecord
  belongs_to :profit_share_pass
  belongs_to :admin_user
end
