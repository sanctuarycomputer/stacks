class CreateQboProfitAndLossLineItems < ActiveRecord::Migration[6.1]
  def change
    create_table :qbo_profit_and_loss_line_items do |t|
      t.references :qbo_account, null: false, foreign_key: true, index: false
      # Cascade at the FK level: find_or_fetch_for_range(force:) uses
      # delete_all, which skips AR callbacks.
      t.references :qbo_profit_and_loss_report, null: false,
        foreign_key: { on_delete: :cascade }, index: false
      t.date :starts_at, null: false
      t.string :accounting_method, null: false
      t.integer :position, null: false
      t.text :label, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false
      t.timestamps
    end

    add_index :qbo_profit_and_loss_line_items,
      [:qbo_profit_and_loss_report_id, :accounting_method, :position],
      unique: true, name: "idx_pnl_line_items_report_method_position"
    add_index :qbo_profit_and_loss_line_items,
      [:qbo_account_id, :accounting_method, :starts_at],
      name: "idx_pnl_line_items_account_method_month"
  end
end
