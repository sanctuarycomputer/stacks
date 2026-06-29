class CreateEmbeddings < ActiveRecord::Migration[6.1]
  def change
    create_table :embeddings do |t|
      t.references :owner, polymorphic: true, null: false
      t.string :model, null: false
      t.column :embedding, :vector, limit: 1024
      t.timestamps
    end
    add_index :embeddings, [:owner_type, :owner_id, :model], unique: true, name: 'index_embeddings_on_owner_and_model'
    add_index :embeddings, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
