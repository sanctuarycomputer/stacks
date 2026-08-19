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

  test "ship_staleness classifies by 7/14 day boundaries" do
    travel_to(Time.zone.parse("2026-08-18 12:00:00")) do
      pt = ProjectTracker.new(name: "X").tap { |t| t.save!(validate: false) }
      assert_equal :never, ProjectTracker.ship_staleness(nil)
      # 7 days ago: exactly on the weekly boundary — must be :fresh (not stale)
      assert_equal :fresh,  ProjectTracker.ship_staleness(make_ship(pt, sent_at: Time.zone.parse("2026-08-11 12:00:00")))
      # 8 days ago: just past the weekly threshold — :stale
      assert_equal :stale,  ProjectTracker.ship_staleness(make_ship(pt, sent_at: Time.zone.parse("2026-08-10 12:00:00")))
      # 14 days ago: still stale, not yet overdue
      assert_equal :stale,  ProjectTracker.ship_staleness(make_ship(pt, sent_at: Time.zone.parse("2026-08-04 12:00:00")))
      # 15 days ago: past the overdue threshold
      assert_equal :overdue, ProjectTracker.ship_staleness(make_ship(pt, sent_at: Time.zone.parse("2026-08-03 12:00:00")))
    end
  end
end
