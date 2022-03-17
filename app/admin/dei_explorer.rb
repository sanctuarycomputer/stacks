ActiveAdmin.register_page "DEI Explorer" do
  menu label: "DEI Explorer", parent: "Team"

  content title: proc { I18n.t("active_admin.dei_explorer") } do
    BROAD_BANDS = ["J", "ML", "EML", "S", "L"]
    COLORS = Stacks::Utils::COLORS
    dei_rollup = DeiRollup.order(created_at: :desc).first
    total = dei_rollup.data.dig("meta", "total")

    cultural_background_raw_data = dei_rollup.data["cultural_background"]
      .filter{|d| d["skill_bands"].length > 0}
    cultural_background_data = {
      labels: cultural_background_raw_data.map{|d| d["name"]},
      datasets: [{
        data: cultural_background_raw_data.map{|d| d["skill_bands"].count},
        backgroundColor: [*COLORS, *COLORS],
      }]
    };
    considered_non_us = (cultural_background_raw_data.reduce(0) do |acc, d|
      d["name"] == "US American" ? acc : [*acc, *d["admin_user_ids"]]
    end).uniq.count
    cultural_background_admin_ids =
      cultural_background_raw_data.reduce([]){|acc, d| [*acc, *d["admin_user_ids"]]}
    multiple_cultural_backgrounds_count =
      cultural_background_admin_ids.select{|e| cultural_background_admin_ids.count(e) > 1}.count

    racial_background_raw_data = dei_rollup.data["racial_background"]
      .filter{|d| d["skill_bands"].length > 0}
    racial_background_data = {
      labels: racial_background_raw_data.map{|d| d["name"]},
      datasets: [{
        data: racial_background_raw_data.map{|d| d["skill_bands"].count},
        backgroundColor: COLORS,
      }]
    };
    considered_bipoc = (racial_background_raw_data.reduce([]) do |acc, d|
      d["name"] == "White" ? acc : [*acc, *d["admin_user_ids"]]
    end).uniq.count
    racial_background_admin_ids =
      racial_background_raw_data.reduce([]){|acc, d| [*acc, *d["admin_user_ids"]]}
    multiple_racial_backgrounds_count =
      racial_background_admin_ids.select{|e| racial_background_admin_ids.count(e) > 1}.count

    gender_identity_raw_data = dei_rollup.data["gender_identity"]
      .filter{|d| d["skill_bands"].length > 0}
    gender_identity_data = {
      labels: gender_identity_raw_data.map{|d| d["name"]},
      datasets: [{
        data: gender_identity_raw_data.map{|d| d["skill_bands"].count},
        backgroundColor: [*COLORS, *COLORS],
      }]
    };
    considered_female = gender_identity_raw_data.reduce(0) do |acc, d|
      d["name"] == "Female" ? acc + d["skill_bands"].count : acc
    end
    # Would love a better suggestion for these variable names
    considered_gender_nonconforming = (gender_identity_raw_data.reduce(0) do |acc, d|
      if ["Female", "Male", "Cisgender"].include?(d["name"])
        acc
      else
        [*acc, *d["admin_user_ids"]]
      end
    end).uniq.count
    gender_nonconforming_names = gender_identity_raw_data.reduce([]) do |acc, d|
      if ["Female", "Male", "Cisgender"].include?(d["name"])
        acc
      else
        acc << d["name"]
      end
    end
    gender_identity_admin_ids =
      gender_identity_raw_data.reduce([]){|acc, d| [*acc, *d["admin_user_ids"]]}
    multiple_gender_identities_count =
      gender_identity_admin_ids.select{|e| gender_identity_admin_ids.count(e) > 1}.count

    community_raw_data = dei_rollup.data["community"]
      .filter{|d| d["skill_bands"].length > 0}
    community_data = {
      labels: community_raw_data.map{|d| d["name"]},
      datasets: [{
        data: community_raw_data.map{|d| d["skill_bands"].count},
        backgroundColor: [*COLORS, *COLORS],
      }]
    };
    considered_neurodiverse = community_raw_data.reduce(0) do |acc, d|
      d["name"] == "Neurodiverse" ? acc + d["skill_bands"].count : acc
    end
    community_admin_ids =
      community_raw_data.reduce([]){|acc, d| [*acc, *d["admin_user_ids"]]}
    multiple_communities_count =
      community_admin_ids.select{|e| community_admin_ids.count(e) > 1}.count

    skill_level_by_racial_background,
    skill_level_by_cultural_background,
    skill_level_by_gender_identity,
    skill_level_by_community = [
      racial_background_raw_data,
      cultural_background_raw_data,
      gender_identity_raw_data,
      community_raw_data
    ].map do |set|
      {
        labels: BROAD_BANDS,
        datasets: (set.map do |d|
          {
            label: d["name"],
            backgroundColor: COLORS[set.index(d)],
            data: (BROAD_BANDS.map do |bb|
              d["skill_bands"].filter{|b| b.starts_with?(bb)}.count
            end)
          }
        end)
      }
    end

    render(partial: "dei_data", locals: {
      # Meta
      total: total,

      # Racial Backgrounds
      skill_level_by_racial_background: skill_level_by_racial_background,
      racial_background_data: racial_background_data,
      racial_background_raw_data: racial_background_raw_data,
      considered_bipoc: considered_bipoc,
      multiple_racial_backgrounds_count: multiple_racial_backgrounds_count,

      # Cultural Backgrounds
      skill_level_by_cultural_background: skill_level_by_cultural_background,
      cultural_background_data: cultural_background_data,
      cultural_background_raw_data: cultural_background_raw_data,
      considered_non_us: considered_non_us,
      multiple_cultural_backgrounds_count: multiple_cultural_backgrounds_count,

      # Gender Identities
      skill_level_by_gender_identity: skill_level_by_gender_identity,
      gender_identity_data: gender_identity_data,
      gender_identity_raw_data: gender_identity_raw_data,
      considered_female: considered_female,
      considered_gender_nonconforming: considered_gender_nonconforming,
      gender_nonconforming_names: gender_nonconforming_names,
      multiple_gender_identities_count: multiple_gender_identities_count,

      # Communities
      skill_level_by_community: skill_level_by_community,
      community_data: community_data,
      community_raw_data: community_raw_data,
      considered_neurodiverse: considered_neurodiverse,
      multiple_communities_count: multiple_communities_count
    })
  end
end
