require "test_helper"

# Covers the no-op-skip fix for the Forecast sync: an unconditional upsert_all rewrote
# every overlapping record on every sync window, churning forecast_assignments to ~71M
# updates / 26GB of bloat for ~46k live rows. upsert_changed! now writes only new/changed
# rows while still reporting every seen id so prune-by-absence stays correct.
class StacksForecastTest < ActiveSupport::TestCase
  def row(forecast_id, updated_at, allocation: 100)
    {
      forecast_id: forecast_id, start_date: "2024-01-01", end_date: "2024-01-31",
      allocation: allocation, notes: nil, updated_at: updated_at, updated_by_id: 1,
      project_id: 1, person_id: 1, placeholder_id: nil,
      repeated_assignment_set_id: nil, active_on_days_off: false, data: { "id" => forecast_id },
    }
  end

  # allocate skips initialize (which needs Forecast API config); we only exercise the helper.
  def forecast = Stacks::Forecast.allocate

  test "first sync upserts all rows and returns every seen id" do
    ids = forecast.send(:upsert_changed!, ForecastAssignment,
                        [row(1, "2024-01-01T00:00:00Z"), row(2, "2024-01-02T00:00:00Z")])
    assert_equal [1, 2], ids
    assert_equal 2, ForecastAssignment.where(forecast_id: [1, 2]).count
  end

  test "re-syncing unchanged rows skips the write entirely but still reports them as seen" do
    data = [row(1, "2024-01-01T00:00:00Z"), row(2, "2024-01-02T00:00:00Z")]
    forecast.send(:upsert_changed!, ForecastAssignment, data)

    ForecastAssignment.expects(:upsert_all).never # the bug: this used to fire every time
    ids = forecast.send(:upsert_changed!, ForecastAssignment, data)
    assert_equal [1, 2], ids, "unchanged-but-present rows must still count as seen so prune won't delete them"
  end

  test "only rows whose Forecast updated_at advanced (or are new) are rewritten" do
    forecast.send(:upsert_changed!, ForecastAssignment,
                  [row(1, "2024-01-01T00:00:00Z", allocation: 100), row(2, "2024-01-02T00:00:00Z", allocation: 100)])

    # row 1 unchanged; row 2's updated_at advances with a new allocation; row 3 is new.
    next_data = [
      row(1, "2024-01-01T00:00:00Z", allocation: 100),
      row(2, "2024-02-02T00:00:00Z", allocation: 50),
      row(3, "2024-03-01T00:00:00Z", allocation: 25),
    ]
    captured = nil
    ForecastAssignment.stubs(:upsert_all).with { |rows, **| captured = rows.map { |r| r[:forecast_id] }; true }
    ids = forecast.send(:upsert_changed!, ForecastAssignment, next_data)

    assert_equal [2, 3], captured, "only the changed + new rows are sent to upsert_all"
    assert_equal [1, 2, 3], ids, "all seen ids are still returned for pruning"
  end

  test "a changed row's new values actually land in the database" do
    forecast.send(:upsert_changed!, ForecastAssignment, [row(1, "2024-01-01T00:00:00Z", allocation: 100)])
    forecast.send(:upsert_changed!, ForecastAssignment, [row(1, "2024-02-01T00:00:00Z", allocation: 42)])
    assert_equal 42, ForecastAssignment.find_by(forecast_id: 1).allocation
  end
end
