ActiveAdmin.register_page "DEI Explorer" do
  menu if: proc { current_admin_user.email == "hugh@sanctuary.computer" },
       label: "DEI Explorer",
       priority: 2

  content title: proc { I18n.t("active_admin.dei_explorer") } do
    COLORS = Stacks::Utils::COLORS
    dei_rollup = DeiRollup.order(created_at: :desc).first

    cultural_background_raw_data = dei_rollup.data["cultural_background"]
      .filter{|d| d["skill_bands"].length > 0}
    cultural_background_data = {
      labels: cultural_background_raw_data.map{|d| d["name"]},
      datasets: [{
        data: cultural_background_raw_data.map{|d| d["skill_bands"].count},
        backgroundColor: [*COLORS, *COLORS],
      }]
    };

    racial_background_raw_data = dei_rollup.data["racial_background"]
      .filter{|d| d["skill_bands"].length > 0}
    racial_background_data = {
      labels: racial_background_raw_data.map{|d| d["name"]},
      datasets: [{
        data: racial_background_raw_data.map{|d| d["skill_bands"].count},
        backgroundColor: COLORS,
      }]
    };

    gender_identity_raw_data = dei_rollup.data["gender_identity"]
      .filter{|d| d["skill_bands"].length > 0}
    gender_identity_data = {
      labels: gender_identity_raw_data.map{|d| d["name"]},
      datasets: [{
        data: gender_identity_raw_data.map{|d| d["skill_bands"].count},
        backgroundColor: [*COLORS, *COLORS],
      }]
    };

    community_raw_data = dei_rollup.data["community"]
      .filter{|d| d["skill_bands"].length > 0}
    community_data = {
      labels: community_raw_data.map{|d| d["name"]},
      datasets: [{
        data: community_raw_data.map{|d| d["skill_bands"].count},
        backgroundColor: [*COLORS, *COLORS],
      }]
    };

    distribution_by =
      case params["skill-levels"]
      when nil
        cultural_background_raw_data
      when "by-cultural-background"
        cultural_background_raw_data
      when "by-racial-background"
        racial_background_raw_data
      when "by-gender-identity"
        gender_identity_raw_data
      when "by-community"
        community_raw_data
      else
        cultural_background_raw_data
      end

    broad_bands = ["J", "ML", "EML", "S", "L"]
    set = distribution_by.map do |rbd|
      {
        label: rbd["name"],
        backgroundColor: COLORS[distribution_by.index(rbd)],
        data: (broad_bands.map do |bb|
          rbd["skill_bands"].filter{|b| b.starts_with?(bb)}.count
        end)
      }
    end

    skill_level_distribution_data = {
      labels: broad_bands,
      datasets: set
    };

    render(partial: "dei_data", locals: {
      cultural_background_data: cultural_background_data,
      racial_background_data: racial_background_data,
      gender_identity_data: gender_identity_data,
      community_data: community_data,
      skill_level_distribution_data: skill_level_distribution_data
    })
  end
end
