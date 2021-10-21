class CreateRacialBackgrounds < ActiveRecord::Migration[6.0]
  def change
    create_table :racial_backgrounds do |t|
      t.string :name
      t.string :description
      t.boolean :opt_out

      t.timestamps
    end
  end
end
