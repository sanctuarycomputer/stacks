require "test_helper"

class ProjectTrackerProvisionTest < ActiveSupport::TestCase
  test "provisions a bare tracker with MSA/SOW links" do
    tracker, warnings = ProjectTracker.provision!(
      name: "Qualitate Retainer",
      msa_url: "https://example.com/msa", sow_url: "https://example.com/sow",
    )
    assert tracker.persisted?
    assert_equal "https://example.com/msa", tracker.project_tracker_links.find { |l| l.link_type == "msa" }.url
    assert_equal "https://example.com/sow", tracker.project_tracker_links.find { |l| l.link_type == "sow" }.url
    assert_empty tracker.forecast_projects
    assert_empty warnings
  end

  test "falls back to placeholder links with a warning when urls are omitted" do
    tracker, warnings = ProjectTracker.provision!(name: "T2")
    assert tracker.persisted?
    assert tracker.project_tracker_links.find { |l| l.link_type == "msa" }.url.include?("todo")
    assert warnings.any? { |w| w.downcase.include?("msa") }
    assert warnings.any? { |w| w.downcase.include?("sow") }
  end
end
