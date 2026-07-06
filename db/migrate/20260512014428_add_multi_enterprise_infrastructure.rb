class AddMultiEnterpriseInfrastructure < ActiveRecord::Migration[6.1]
  def up
    # 1. Enterprise's Deel legal entity ID
    add_column :enterprises, :deel_legal_entity_id, :string
    add_index :enterprises, :deel_legal_entity_id, unique: true, where: "deel_legal_entity_id IS NOT NULL"

    # 2. Deel contract caches its legal entity ID for routing
    add_column :deel_contracts, :deel_legal_entity_id, :string
    add_index :deel_contracts, :deel_legal_entity_id

    # Inline backfill from existing data JSONB. Deel's /contracts payload
    # nests the legal entity under client.team (id + name), not client.legal_entity.
    execute(<<~SQL)
      UPDATE deel_contracts
         SET deel_legal_entity_id = data#>>'{client,team,id}'
       WHERE deel_legal_entity_id IS NULL
    SQL

    # 3. Enterprise <-> ForecastClient join table
    create_table :enterprise_forecast_clients do |t|
      t.references :enterprise, null: false, foreign_key: true
      t.integer :forecast_client_id, null: false
      t.timestamps
    end
    add_index :enterprise_forecast_clients, :forecast_client_id, unique: true
    add_foreign_key :enterprise_forecast_clients, :forecast_clients, primary_key: :forecast_id
  end

  def down
    remove_foreign_key :enterprise_forecast_clients, :forecast_clients
    drop_table :enterprise_forecast_clients

    remove_index :deel_contracts, :deel_legal_entity_id
    remove_column :deel_contracts, :deel_legal_entity_id

    remove_index :enterprises, :deel_legal_entity_id
    remove_column :enterprises, :deel_legal_entity_id
  end
end
