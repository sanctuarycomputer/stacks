class BackfillContributorsForForecastPeople < ActiveRecord::Migration[6.1]
  # Creates a Contributor row for every active ForecastPerson that doesn't
  # have one. `Contributor.after_create` cascades into
  # `Ledger.ensure_for_contributor!`, so each new Contributor immediately
  # receives a Ledger for every existing Enterprise — no second pass needed.
  #
  # Pairs with the new daily-task hook so this stays converged going forward
  # (see lib/tasks/stacks.rake :daily_enterprise_tasks).
  def up
    created = Contributor.ensure_all_for_forecast_people!
    say "Created #{created} Contributor row(s) for active ForecastPersons that lacked one"
  end

  def down
    # No-op — removing Contributor rows on rollback would orphan ledger
    # items and is destructive. The forward-direction backfill is
    # idempotent, so re-running up is safe.
  end
end
