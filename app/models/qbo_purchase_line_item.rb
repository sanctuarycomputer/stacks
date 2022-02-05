class QboPurchaseLineItem < ApplicationRecord
  scope :matched, -> {
          QboPurchaseLineItem.where.not(expense_group: nil)
        }
  scope :unmatched, -> {
          QboPurchaseLineItem.where(expense_group: nil)
        }
  scope :errored , -> {
          QboPurchaseLineItem.where("(data->'errors') is not null")
        }
  belongs_to :expense_group, optional: true
end
