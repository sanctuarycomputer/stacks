class CreateExpenseGroups < ActiveRecord::Migration[6.0]
  def change
    create_table :expense_groups do |t|
      t.string :name
      t.string :matcher

      t.timestamps
    end

    add_index :expense_groups, :name, unique: true
    add_index :expense_groups, :matcher, unique: true
  end
end
