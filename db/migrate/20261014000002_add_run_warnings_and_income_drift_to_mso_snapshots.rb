class AddRunWarningsAndIncomeDriftToMsoSnapshots < ActiveRecord::Migration[6.1]
  def change
    # Written once, by the run: things that were not finished when the month
    # was run and could still move its figures (another company's pass not
    # complete, an executive's payout not accepted). Ids and counts only. A
    # warning, never a refusal.
    add_column :mso_snapshots, :run_warnings, :jsonb, null: false, default: {}
    # Written by the nightly check, and rewritten every night: where a fresh
    # computation of the month no longer gives the figures this run stored
    # (income that landed after the run). Not one of the run's own figures.
    add_column :mso_snapshots, :income_drift, :jsonb, null: false, default: {}
  end
end
