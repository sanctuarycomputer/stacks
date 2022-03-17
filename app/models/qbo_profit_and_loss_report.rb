class QboProfitAndLossReport < ApplicationRecord
  def find_row(label)
    data["rows"].find {|r| r[0] == label } || [nil, 0]
  end

  def self.find_or_fetch_for_range(start_of_range, end_of_range, force = false)
    ActiveRecord::Base.transaction do
      existing = where(starts_at: start_of_range, ends_at: end_of_range)
      if force
        existing.delete_all
      else
        return existing.first if existing.any?
      end

      report = Stacks::Quickbooks.fetch_profit_and_loss_report_for_range(
        start_of_range,
        end_of_range
      )

      create!(
        starts_at: start_of_range,
        ends_at: end_of_range,
        data: { rows: report.all_rows }
      )
    end
  end
end
