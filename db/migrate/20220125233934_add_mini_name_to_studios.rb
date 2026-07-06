class AddMiniNameToStudios < ActiveRecord::Migration[6.0]
  def change
    add_column :studios, :mini_name, :string
  end
end
