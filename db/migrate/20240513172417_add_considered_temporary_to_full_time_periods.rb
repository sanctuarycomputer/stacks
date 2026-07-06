class AddConsideredTemporaryToFullTimePeriods < ActiveRecord::Migration[6.0]
  def change
    add_column :full_time_periods, :considered_temporary, :boolean, default: false
  end
end
