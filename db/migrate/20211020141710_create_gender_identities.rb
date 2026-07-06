class CreateGenderIdentities < ActiveRecord::Migration[6.0]
  def change
    create_table :gender_identities do |t|
      t.string :name
      t.boolean :opt_out

      t.timestamps
    end
  end
end
