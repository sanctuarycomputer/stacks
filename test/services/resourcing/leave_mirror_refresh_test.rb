require "test_helper"

class Resourcing::LeaveMirrorRefreshTest < ActiveSupport::TestCase
  test "run! mirrors each non-archived person's leave into runn_leave_mirrors" do
    runn = mock("runn")
    runn.stubs(:get_people).returns([
      { "id" => 10, "isArchived" => false },
      { "id" => 11, "isArchived" => true },  # skipped
    ])
    runn.expects(:get_leave_for_person).with(10).returns([
      { "startDate" => "2030-05-10", "endDate" => "2030-05-15", "minutesPerDay" => 480 },
    ])
    runn.expects(:get_leave_for_person).with(11).never

    svc = Resourcing::LeaveMirrorRefresh.new
    svc.runn = runn
    count = svc.run!
    assert_equal 1, count
    row = RunnLeaveMirror.find_by(runn_person_id: 10)
    assert_equal Date.new(2030, 5, 10), row.start_date
    assert row.refreshed_at.present?
  end

  test "run! replaces a person's prior leave rows" do
    RunnLeaveMirror.create!(runn_person_id: 10, start_date: Date.new(2029, 1, 1), end_date: Date.new(2029, 1, 2), refreshed_at: Time.current)
    runn = mock("runn")
    runn.stubs(:get_people).returns([{ "id" => 10, "isArchived" => false }])
    runn.stubs(:get_leave_for_person).returns([{ "startDate" => "2030-05-10", "endDate" => "2030-05-15" }])
    svc = Resourcing::LeaveMirrorRefresh.new
    svc.runn = runn
    svc.run!
    assert_equal [Date.new(2030, 5, 10)], RunnLeaveMirror.where(runn_person_id: 10).pluck(:start_date)
  end
end
