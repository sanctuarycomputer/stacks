require "test_helper"

class ProfitShareManualInclusionPeriodTest < ActiveSupport::TestCase
  setup do
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "included@example.com", data: {})
    @contributor = fp.contributor || Contributor.create!(forecast_person: fp)
  end

  def build(**attrs)
    ProfitShareManualInclusionPeriod.new({ contributor: @contributor, started_at: Date.new(2026, 7, 1), note: "ops" }.merge(attrs))
  end

  test "covers whole months only, and needs a note" do
    assert build.valid?
    refute build(started_at: Date.new(2026, 7, 2)).valid?
    refute build(ended_at: Date.new(2026, 9, 29)).valid?
    assert build(ended_at: Date.new(2026, 9, 30)).valid?
    refute build(note: "").valid?
  end

  test "a contributor's periods can't overlap, including open-ended ones" do
    build.save!
    refute build(started_at: Date.new(2027, 1, 1)).valid?, "an open-ended period covers every later month"
  end

  test "covers? is true for every month the period touches" do
    period = build(ended_at: Date.new(2026, 9, 30))

    refute period.covers?(Date.new(2026, 6, 15))
    assert period.covers?(Date.new(2026, 7, 31))
    assert period.covers?(Date.new(2026, 9, 1))
    refute period.covers?(Date.new(2026, 10, 1))
    assert build.covers?(Date.new(2030, 1, 1)), "open-ended"
  end
end
