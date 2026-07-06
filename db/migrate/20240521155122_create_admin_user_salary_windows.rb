class CreateAdminUserSalaryWindows < ActiveRecord::Migration[6.0]
  def change
    create_table :admin_user_salary_windows do |t|
      t.references :admin_user, null: false, index: true, foreign_key: true
      t.decimal :salary, null: false
      t.date :start_date, null: false
      t.date :end_date
      t.timestamps
    end
  end
end
