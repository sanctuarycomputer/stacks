require 'test_helper'

class ProjectTrackerWeeklyShipsTest < ActiveSupport::TestCase
  def make_doc
    Document.create!(source: :google_groups, external_id: "<#{SecureRandom.hex(6)}@m>",
                     occurred_at: Time.zone.now,
                     raw_metadata: { "group_email" => "ships@sanctuary.computer",
                                     "gmail_message_ids" => [] })
  end

  def make_ship(tracker, sent_at:)
    ship = WeeklyShip.new(document: make_doc, project_tracker: tracker,
                          sent_at: sent_at, matched_by: :llm)
    ship.via_sweep = true
    ship.save!
    ship
  end

  test "last_weekly_ship returns the most recent by sent_at" do
    pt = ProjectTracker.new(name: "X").tap { |t| t.save!(validate: false) }
    make_ship(pt, sent_at: 10.days.ago)
    newest = make_ship(pt, sent_at: 2.days.ago)
    assert_equal newest.id, pt.last_weekly_ship.id
  end

  test "latest_by_tracker bulk-loads one newest ship per tracker" do
    a = ProjectTracker.new(name: "A").tap { |t| t.save!(validate: false) }
    b = ProjectTracker.new(name: "B").tap { |t| t.save!(validate: false) }
    make_ship(a, sent_at: 5.days.ago)
    newest_a = make_ship(a, sent_at: 1.day.ago)
    newest_b = make_ship(b, sent_at: 3.days.ago)
    c = ProjectTracker.new(name: "C").tap { |t| t.save!(validate: false) }

    map = WeeklyShip.latest_by_tracker([a.id, b.id, c.id])
    assert_equal newest_a.id, map[a.id].id
    assert_equal newest_b.id, map[b.id].id
    assert_nil map[c.id]
  end

  test "ship_staleness classifies by 10/30-day gaps from the forecast anchor" do
    pt = ProjectTracker.new(name: "X").tap { |t| t.save!(validate: false) }
    anchor = Date.new(2026, 8, 18)
    assert_equal :never, ProjectTracker.ship_staleness(nil, anchor: anchor)
    # 10 days before the anchor: exactly on the tolerance — :fresh
    assert_equal :fresh, ProjectTracker.ship_staleness(make_ship(pt, sent_at: Time.zone.parse("2026-08-08 12:00:00")), anchor: anchor)
    # ship AFTER the anchor (shipped since the last recorded hour) — :fresh
    assert_equal :fresh, ProjectTracker.ship_staleness(make_ship(pt, sent_at: Time.zone.parse("2026-08-20 12:00:00")), anchor: anchor)
    # 11 days: just past tolerance — :stale
    assert_equal :stale, ProjectTracker.ship_staleness(make_ship(pt, sent_at: Time.zone.parse("2026-08-07 12:00:00")), anchor: anchor)
    # 30 days: still stale, not yet overdue
    assert_equal :stale, ProjectTracker.ship_staleness(make_ship(pt, sent_at: Time.zone.parse("2026-07-19 12:00:00")), anchor: anchor)
    # 31 days: overdue
    assert_equal :overdue, ProjectTracker.ship_staleness(make_ship(pt, sent_at: Time.zone.parse("2026-07-18 12:00:00")), anchor: anchor)
  end

  test "internal_client? is true only when all forecast projects bill our own companies" do
    pt = ProjectTracker.new(name: "X").tap { |t| t.save!(validate: false) }

    pt.stubs(:forecast_projects).returns([stub(is_internal?: true), stub(is_internal?: true)])
    assert pt.internal_client?

    pt.unstub(:forecast_projects)
    pt.stubs(:forecast_projects).returns([stub(is_internal?: true), stub(is_internal?: false)])
    refute pt.internal_client?

    pt.unstub(:forecast_projects)
    pt.stubs(:forecast_projects).returns([])
    refute pt.internal_client?, "trackers with no forecast projects are not assumed internal"
  end

  test "last_recorded_forecast_date reads the snapshot, capped at today" do
    travel_to(Time.zone.parse("2026-08-18 12:00:00")) do
      pt = ProjectTracker.new(name: "X").tap { |t| t.save!(validate: false) }

      pt.snapshot = { "last_forecast_assignment_end_date" => "2026-07-16" }
      assert_equal Date.new(2026, 7, 16), pt.last_recorded_forecast_date

      # Future-dated allocations can't have recorded hours yet — cap at today.
      pt.snapshot = { "last_forecast_assignment_end_date" => "2026-09-30" }
      assert_equal Date.new(2026, 8, 18), pt.last_recorded_forecast_date

      # No snapshot → fall back to today (degrades to calendar staleness).
      pt.snapshot = {}
      assert_equal Date.new(2026, 8, 18), pt.last_recorded_forecast_date
    end
  end
end
