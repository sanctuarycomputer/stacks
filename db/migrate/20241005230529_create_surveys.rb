class CreateSurveys < ActiveRecord::Migration[6.0]
  def change
    create_table :surveys do |t|
      t.string :title, null: false
      t.text :description, null: false
      t.date :opens_at
      t.datetime :closed_at
      t.timestamps
    end
  end
end
