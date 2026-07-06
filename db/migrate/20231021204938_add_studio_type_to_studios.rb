class AddStudioTypeToStudios < ActiveRecord::Migration[6.0]
  def change
    add_column :studios, :studio_type, :integer, default: 0
  end
end