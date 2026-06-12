class AddModeAndPaymentMethodsToLedgers < ActiveRecord::Migration[6.1]
  # Per the QBO-bound cutover design:
  # - `mode` controls balance computation. Default :legacy preserves today's behavior.
  # - `payment_methods` is a Postgres text[] with values from %w[deel qbo].
  #   Backfilled from the contributor's DeelPerson country: non-US Deel → ["deel"],
  #   everyone else → ["qbo"].
  def up
    add_column :ledgers, :mode, :integer, null: false, default: 0
    add_column :ledgers, :payment_methods, :string, array: true, null: false, default: []
    add_index  :ledgers, :mode
    add_index  :ledgers, :payment_methods, using: :gin

    Ledger.reset_column_information

    Ledger.includes(contributor: :deel_person).find_each do |ledger|
      contributor = ledger.contributor
      next if contributor.nil?

      dp = contributor.deel_person
      country = dp&.data.is_a?(Hash) ? dp.data["country"].to_s.upcase : nil
      is_non_us_deel = dp.present? && country.present? && country != "US"

      ledger.update_column(:payment_methods, is_non_us_deel ? %w[deel] : %w[qbo])
    end
  end

  def down
    remove_index  :ledgers, :payment_methods
    remove_index  :ledgers, :mode
    remove_column :ledgers, :payment_methods
    remove_column :ledgers, :mode
  end
end
