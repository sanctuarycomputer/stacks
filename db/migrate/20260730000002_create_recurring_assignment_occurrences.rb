class CreateRecurringAssignmentOccurrences < ActiveRecord::Migration[6.1]
  def change
    create_table :recurring_assignment_occurrences do |t|
      t.references :recurring_assignment, null: false, foreign_key: true,
        index: { name: "idx_recurring_occurrences_on_recurring_assignment_id" }
      t.date :occurs_on, null: false
      t.bigint :forecast_assignment_id
      t.string :status, null: false, default: "materialized"
      t.timestamps
    end
    add_index :recurring_assignment_occurrences,
      [:recurring_assignment_id, :occurs_on],
      unique: true,
      name: "idx_recurring_occurrences_on_rule_and_date"
    add_index :recurring_assignment_occurrences, :forecast_assignment_id,
      name: "idx_recurring_occurrences_on_forecast_assignment_id"
  end
end
