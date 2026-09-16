module ContributorProjections
  # One projected ledger line. Ids and names only (no AR objects) so a Result
  # marshals small into Rails.cache. `month` is the month's starts_at Date.
  Line = Struct.new(
    :kind, :ledger_id, :enterprise_id, :contributor_id,
    :project_tracker_id, :project_tracker_name,
    :hours, :rate, :amount, :description,
    :tentative, :rate_mismatch, :month,
    keyword_init: true
  )
end
