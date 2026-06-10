# Local mirror of one QBO chart-of-accounts entry ("Account" in the QBO
# API — that name is taken locally by the realm-connection model, hence
# "chart account"). Synced by QboAccount#sync_all_chart_accounts!,
# following the same upsert pattern as QboVendor / QboBill. Rows that
# disappear from QBO are soft-deactivated (active: false), never deleted,
# so QboBillAccountMapping references can't dangle silently.
class QboChartAccount < ApplicationRecord
  belongs_to :qbo_account

  validates :qbo_id, presence: true
  validates :name, presence: true

  scope :active, -> { where(active: true) }

  def display_label
    acct_num.present? ? "#{name} (#{acct_num})" : name
  end

  def current_balance
    (data || {}).fetch("current_balance", 0).to_f
  end
end
