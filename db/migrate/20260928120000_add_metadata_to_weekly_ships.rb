# The weekly ship grade lives under metadata["scoring"] (Stacks::WeeklyShips::Grader).
# One jsonb column instead of typed grade columns, so the rubric can change without
# another migration (docs/superpowers/specs/2026-09-28-weekly-ship-grading-design.md).
class AddMetadataToWeeklyShips < ActiveRecord::Migration[6.1]
  def change
    add_column :weekly_ships, :metadata, :jsonb, null: false, default: {}
  end
end
