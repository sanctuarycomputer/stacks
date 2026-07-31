require "test_helper"

class ProjectTrackerProvisionTest < ActiveSupport::TestCase
  def forecast_project(forecast_id, code)
    ForecastProject.new(forecast_id: forecast_id, code: code, name: "P#{forecast_id}", client_id: 1).save!(validate: false)
    forecast_id
  end

  test "provisions a tracker with MSA/SOW links and attached forecast projects" do
    fp = forecast_project(1001, "QUAL-1")
    tracker, warnings = ProjectTracker.provision!(
      name: "Qualitate Retainer", forecast_project_ids: [fp],
      msa_url: "https://example.com/msa", sow_url: "https://example.com/sow",
    )
    assert tracker.persisted?
    assert_equal "https://example.com/msa", tracker.project_tracker_links.find { |l| l.link_type == "msa" }.url
    assert_equal "https://example.com/sow", tracker.project_tracker_links.find { |l| l.link_type == "sow" }.url
    assert_equal [1001], tracker.forecast_projects.map(&:forecast_id)
    assert_empty warnings
  end

  test "falls back to placeholder links with a warning when urls are omitted" do
    fp = forecast_project(1002, "QUAL-2")
    tracker, warnings = ProjectTracker.provision!(name: "T2", forecast_project_ids: [fp])
    assert tracker.persisted?
    assert tracker.project_tracker_links.find { |l| l.link_type == "msa" }.url.include?("todo")
    assert warnings.any? { |w| w.downcase.include?("msa") }
    assert warnings.any? { |w| w.downcase.include?("sow") }
  end

  test "raises when an attached forecast project has no code" do
    ForecastProject.new(forecast_id: 1003, code: nil, name: "NoCode", client_id: 1).save!(validate: false)
    assert_raises(ActiveRecord::RecordInvalid) do
      ProjectTracker.provision!(name: "T3", forecast_project_ids: [1003],
        msa_url: "https://e.com/m", sow_url: "https://e.com/s")
    end
  end
end
