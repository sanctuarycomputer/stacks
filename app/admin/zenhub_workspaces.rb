ActiveAdmin.register ZenhubWorkspace do
  menu label: "Zenhub Workspaces", parent: "Github & Zenhub"
  config.filters = true
  config.paginate = false
  actions :index, :show

  action_item :issues, only: :show do
    link_to("Zenhub Issues ↗", admin_zenhub_workspace_zenhub_issues_path(resource))
  end

  index download_links: false do
    column :name do |workspace|
      link_to(workspace.name, workspace.html_url, rel: "noopener noreferrer", target: "_blank")
    end

    column :total_issues do |workspace|
      workspace.zenhub_issues.count
    end

    column :total_story_points

    column :github_repos

    actions defaults: false do |workspace|
      text_node link_to("Zenhub Issues ↗", admin_zenhub_workspace_zenhub_issues_path(workspace))
    end
  end

  show do
    COLORS = Stacks::Utils::COLORS
    sanctu = Studio.find(3)
    zenhub_workspace = resource

    all_gradations = ["month", "quarter", "year", "trailing_3_months", "trailing_4_months", "trailing_6_months", "trailing_12_months"]
    default_gradation = "month"
    current_gradation =
      params["gradation"] || default_gradation
    current_gradation =
      default_gradation unless all_gradations.include?(current_gradation)

    snapshot =
      sanctu.snapshot[current_gradation] || []
    snapshot_without_ytd = snapshot.reject{|s| s["label"] == "YTD"}
    accounting_method = session[:accounting_method] || "cash"
    datapoints_bearer = "datapoints"

    gh_repo_ids = zenhub_workspace.github_repos.map(&:id)
    prs = GithubPullRequest
      .where(github_repo: gh_repo_ids)
      .merged

    workspace_data = Stacks::Period.for_gradation(current_gradation.to_sym).map do |period|
      period_prs = prs.where(merged_at: period.starts_at..period.ends_at)
      ttm = period_prs.average(:time_to_merge)
      ttms = period_prs.map{|pr| (pr.time_to_merge / 86400.to_f)}
      {
        prs_merged: prs.count,
        time_to_merge_pr: ttm.present? ? (ttm / 86400.to_f) : nil,
      }
    end

    dev_data = {
      labels: snapshot.map{|s| s["label"]},
      datasets: [{
        label: "Sanctuary's Average Time to Merge PR (Days)",
        borderColor: COLORS[2],
        type: 'line',
        data: (snapshot.map do |v|
          v.dig(accounting_method, datapoints_bearer, "time_to_merge_pr", "value").to_f
        end),
        yAxisID: 'y',
      }, {
        label: "#{zenhub_workspace.name} Average Time to Merge PR (Days)",
        borderColor: COLORS[1],
        type: 'line',
        data: (workspace_data.map do |v|
          v[:time_to_merge_pr]
        end),
        yAxisID: 'y',
      }]
    }

    render(partial: "show", locals: {
      zenhub_workspace: resource,
      all_gradations: all_gradations,
      default_gradation: default_gradation,
      dev_data: dev_data
    })
  end
end
