require 'test_helper'
require 'ostruct'

class Stacks::Etl::Meet::CalendarEnricherTest < ActiveSupport::TestCase
  def event(summary:, conf_id: nil, attendees: [])
    OpenStruct.new(
      summary: summary,
      conference_data: conf_id ? OpenStruct.new(conference_id: conf_id) : nil,
      attendees: attendees.map { |email, name| OpenStruct.new(email: email, display_name: name) }
    )
  end

  def enricher_returning(events)
    enr = Stacks::Etl::Meet::CalendarEnricher.new('hugh@sanctuary.computer')
    svc = mock('cal')
    svc.stubs(:list_events).returns(OpenStruct.new(items: events))
    enr.stubs(:service).returns(svc) # private; avoids a real Calendar call
    enr
  end

  test 'matches by meeting code and returns title + attendee emails' do
    enr = enricher_returning([event(summary: 'Standup', conf_id: 'abc-defg-hjk', attendees: [['a@x.co', 'A']])])
    r = enr.enrich(started_at: Time.utc(2026, 1, 1, 9), meeting_code: 'abc-defg-hjk', fallback_title: 'abc-defg-hjk')
    assert_equal 'Standup', r[:title]
    assert_equal ['a@x.co'], r[:attendees].map { |x| x[:email] }
  end

  test 'a code with no matching event returns the fallback and no attendees' do
    enr = enricher_returning([event(summary: 'Other', conf_id: 'zzz')])
    r = enr.enrich(started_at: Time.utc(2026, 1, 1, 9), meeting_code: 'abc-defg-hjk', fallback_title: 'abc-defg-hjk')
    assert_equal 'abc-defg-hjk', r[:title]
    assert_empty r[:attendees]
  end

  test 'matches by exact title hint when there is no code (Drive path)' do
    enr = enricher_returning([event(summary: 'Weekly Sync', conf_id: 'x', attendees: [['b@x.co', nil]])])
    r = enr.enrich(started_at: Time.utc(2026, 1, 1, 9), meeting_code: nil, fallback_title: 'Weekly Sync', title_hint: 'weekly sync')
    assert_equal 'Weekly Sync', r[:title]
    assert_equal ['b@x.co'], r[:attendees].map { |x| x[:email] }
  end

  test 'does not match by time alone (avoids mis-assigning a nearby event)' do
    enr = enricher_returning([event(summary: 'Unrelated', conf_id: 'other', attendees: [['z@x.co', nil]])])
    r = enr.enrich(started_at: Time.utc(2026, 1, 1, 9), meeting_code: 'abc-defg-hjk', fallback_title: 'abc-defg-hjk')
    assert_equal 'abc-defg-hjk', r[:title]
    assert_empty r[:attendees]
  end

  test 'among same-title events it picks the one closest in time (Drive path)' do
    near = event(summary: 'Weekly Sync', conf_id: 'a', attendees: [['near@x.co', nil]])
    near.start = OpenStruct.new(date_time: '2026-01-01T09:05:00Z')
    far = event(summary: 'Weekly Sync', conf_id: 'b', attendees: [['far@x.co', nil]])
    far.start = OpenStruct.new(date_time: '2026-01-01T11:30:00Z')
    enr = enricher_returning([far, near])
    r = enr.enrich(started_at: Time.utc(2026, 1, 1, 9), meeting_code: nil, fallback_title: 'Weekly Sync', title_hint: 'weekly sync')
    assert_equal ['near@x.co'], r[:attendees].map { |x| x[:email] }
  end

  test 'skips room-resource attendees' do
    enr = enricher_returning([event(summary: 'S', conf_id: 'abc', attendees: [['room@resource.calendar.google.com', nil], ['c@x.co', nil]])])
    r = enr.enrich(started_at: Time.utc(2026, 1, 1, 9), meeting_code: 'abc', fallback_title: 'S')
    assert_equal ['c@x.co'], r[:attendees].map { |x| x[:email] }
  end
end
