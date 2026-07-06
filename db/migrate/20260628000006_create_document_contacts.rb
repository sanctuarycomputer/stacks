class CreateDocumentContacts < ActiveRecord::Migration[6.1]
  def change
    create_table :document_contacts do |t|
      t.references :document, null: false, foreign_key: true
      t.references :contact, null: true, foreign_key: true
      t.string :email
      t.string :name
      t.string :role
      t.timestamps
    end
    add_index :document_contacts, [:document_id, :contact_id, :role], unique: true, name: 'index_document_contacts_unique'
  end
end
