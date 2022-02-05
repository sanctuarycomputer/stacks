class ExpenseGroup < ApplicationRecord
  has_many :qbo_purchase_line_items, dependent: :nullify

  after_create :do_matching
  after_update :do_matching
  after_destroy :do_matching

  def do_matching
    Stacks::Expenses.match_all!
  end

  def spent_last_month
    qbo_purchase_line_items.where(
      txn_date: (Date.today - 1.month).beginning_of_month...(Date.today - 1.month).end_of_month
    ).map(&:amount).reduce(&:+)
  end

  def spent_last_year
    qbo_purchase_line_items.where(
      txn_date: (Date.today - 1.year).beginning_of_year...(Date.today - 1.year).end_of_year
    ).map(&:amount).reduce(&:+)
  end

  def spent_all_time
    qbo_purchase_line_items.map(&:amount).reduce(&:+)
  end
end
