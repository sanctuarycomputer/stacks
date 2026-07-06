class EnableVectorExtension < ActiveRecord::Migration[6.1]
  def change
    enable_extension 'vector'
  end
end
