module Mcp
  # Shared ProjectTracker lookup for the project-level BI tools
  # (get_project_burnup, get_project_cost_breakdown, get_project_contributors):
  # accepts a tracker id (all digits) or an exact, case-insensitive name.
  module TrackerResolution
    def resolve_tracker(ref)
      ref = ref.to_s.strip
      return ProjectTracker.find_by(id: ref) if ref.match?(/\A\d+\z/)
      ProjectTracker.where('lower(name) = ?', ref.downcase).first
    end

    def unknown_tracker_error(ref)
      Responses.error("Unknown tracker '#{ref}'. Pass a ProjectTracker id or exact name — use list_project_trackers to find one.")
    end
  end
end
