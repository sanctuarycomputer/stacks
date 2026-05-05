require "test_helper"

class ForecastProjectTest < ActiveSupport::TestCase
  test "#candidates_for_association_with_project_tracker returns already-associated forecast projects even if already associated with a separate project tracker" do
    client = ForecastClient.create!

    forecast_project = ForecastProject.create!({
      id: 1,
      forecast_client: client,
      code: "ABCD-1",
      name: "Test project 1",
      data: {
        archived: false
      }
    })

    project_tracker_links = [
      ProjectTrackerLink.new({
        name: "SOW link",
        url: "https://example.com",
        link_type: "sow"
      }),
      ProjectTrackerLink.new({
        name: "MSA link",
        url: "https://example.com",
        link_type: "msa"
      })
    ]

    ProjectTracker.create!({
      name: "Test project 1",
      forecast_projects: [forecast_project],
      project_tracker_links: project_tracker_links
    })

    newer_project_tracker = ProjectTracker.new({
      name: "Test project 2",
      forecast_projects: [forecast_project],
      project_tracker_links: project_tracker_links
    })

    # For the purposes of this test, bypass the validation that prevents
    # duplicate association of the same forecast project with multiple trackers.
    newer_project_tracker.save(validate: false)

    candidates = ForecastProject.candidates_for_association_with_project_tracker(newer_project_tracker)

    assert_includes(candidates, [forecast_project.display_name, forecast_project.id, {disabled: false}])
  end

  test "#hourly_rate_override_for_email_address parses single entry on its own line" do
    fp = ForecastProject.new
    fp.stubs(:notes).returns("winnie@xxix.co:111.15p/h")
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("winnie@xxix.co"), 0.001
  end

  test "#hourly_rate_override_for_email_address parses multiple entries separated by newlines" do
    fp = ForecastProject.new
    fp.stubs(:notes).returns("winnie@xxix.co:111.15p/h\nsam@xxix.co:99.75p/h")
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("winnie@xxix.co"), 0.001
    assert_in_delta 99.75, fp.hourly_rate_override_for_email_address("sam@xxix.co"), 0.001
  end

  test "#hourly_rate_override_for_email_address parses multiple entries comma-separated on one line" do
    notes = "winnie@xxix.co:111.15p/h, sam@xxix.co:111.15p/h, james@xxix.co:111.15p/h, hugh@sanctuary.computer:111.15p/h, matthew@xxix.co:111.15p/h, ray@xxix.co:99.75p/h"
    fp = ForecastProject.new
    fp.stubs(:notes).returns(notes)
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("winnie@xxix.co"), 0.001
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("sam@xxix.co"), 0.001
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("james@xxix.co"), 0.001
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("hugh@sanctuary.computer"), 0.001
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("matthew@xxix.co"), 0.001
    assert_in_delta 99.75, fp.hourly_rate_override_for_email_address("ray@xxix.co"), 0.001
  end

  test "#hourly_rate_override_for_email_address parses mixed newline and comma-separated entries" do
    fp = ForecastProject.new
    fp.stubs(:notes).returns("winnie@xxix.co:111.15p/h, sam@xxix.co:111.15p/h\njames@xxix.co:99.75p/h")
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("winnie@xxix.co"), 0.001
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("sam@xxix.co"), 0.001
    assert_in_delta 99.75, fp.hourly_rate_override_for_email_address("james@xxix.co"), 0.001
  end

  test "#hourly_rate_override_for_email_address is case-insensitive on email" do
    fp = ForecastProject.new
    fp.stubs(:notes).returns("Winnie@XXIX.CO:111.15p/h")
    assert_in_delta 111.15, fp.hourly_rate_override_for_email_address("winnie@xxix.co"), 0.001
  end

  test "#hourly_rate_override_for_email_address returns nil when notes is blank" do
    fp = ForecastProject.new
    fp.stubs(:notes).returns(nil)
    assert_nil fp.hourly_rate_override_for_email_address("winnie@xxix.co")
  end

  test "#hourly_rate_override_for_email_address returns nil when email is not present in notes" do
    fp = ForecastProject.new
    fp.stubs(:notes).returns("winnie@xxix.co:111.15p/h")
    assert_nil fp.hourly_rate_override_for_email_address("nobody@example.com")
  end

  test "#hourly_rate_override_for_email_address ignores email-like patterns embedded in unrelated prose" do
    fp = ForecastProject.new
    fp.stubs(:notes).returns("Some unrelated text mentioning bob@example.com:50p/h inline.")
    assert_nil fp.hourly_rate_override_for_email_address("bob@example.com")
  end
end
