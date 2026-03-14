class ProfitShare < ApplicationRecord
  acts_as_paranoid
  belongs_to :periodic_report
  belongs_to :contributor

  def applied_at
    periodic_report.period.ends_at
  end

  def payable?
    periodic_report.all_profit_shares_accepted?
  end

  def accepted?
    accepted_at.present?
  end

  def toggle_acceptance!
    if accepted?
      update!(accepted_at: nil)
    else
      update!(accepted_at: DateTime.now)
    end
  end
end
