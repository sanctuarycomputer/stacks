class CreateProfitSharePasses < ActiveRecord::Migration[6.0]
  def change
    create_table :profit_share_passes do |t|

      t.timestamps
    end
  end
end
