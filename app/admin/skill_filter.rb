ActiveAdmin.register_page "Skill Filter" do
  menu parent: "Team"

  content title: proc { I18n.t("active_admin.skill_filter") } do
    selected_filters = 
      params.keys.reduce([]) do |acc, param|
        next acc unless param.starts_with?("filter_group_")
        acc << {
          trait_id: params[param].split(",")[0],
          trait: Trait.includes(:tree).find(params[param].split(",")[0]),
          band: params[param].split(",")[1],
          consistency: params[param].split(",")[2],
        }
        acc
      end
    
    active_team = AdminUser.active
    active_team_without_review = active_team.select{|au| au.archived_reviews.first.nil? }

    filtered_team = selected_filters.reduce(active_team) do |acc, filter|
      acc = acc.select do |au|
        latest_review = au.archived_reviews.first
        next false unless latest_review.present?
        score_tree  = latest_review.finalization.workspace.score_trees.find{|st| st.tree == filter[:trait].tree }
        next false unless score_tree.present?
        score = score_tree.scores.find{|s| s.trait_id == filter[:trait_id].to_i}
        Score.bands[score.band] >= Score.bands[filter[:band]] && Score.consistencies[score.consistency] >= Score.consistencies[filter[:consistency]]
      end
      acc
    end
    
    render(partial: "skill_filter", locals: {
      selected_filters: selected_filters,
      filtered_team: filtered_team,
      active_team_without_review: active_team_without_review
    })
  end
end
