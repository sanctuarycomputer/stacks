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
end
