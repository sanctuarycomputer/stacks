class CreateAcknowledgements < ActiveRecord::Migration[6.0]
  def change
    create_table :acknowledgements do |t|
      t.string :name, null: :false
      t.string :learn_more_url
      t.integer :acknowledgement_type, default: 0

      t.timestamps
    end
  end
end
