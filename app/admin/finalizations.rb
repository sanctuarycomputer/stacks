ActiveAdmin.register Finalization do
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  scope :finalized

  menu if: -> { current_admin_user.is_admin? },
       label: "Workspaces (Admin Only)",
       parent: "Skill Trees",
       priority: 3

  actions :index, :edit, :update
  permit_params workspace_attributes: [
    :id,
    :status,
    :notes,
    :_edit,
    score_trees_attributes: [
      :id,
      :_edit,
      scores_attributes: [
        :id,
        :band,
        :consistency,
        :_edit,
      ],
    ],
  ]

  action_item :archive, only: :edit, if: proc { current_admin_user.is_admin? } do
    if resource.review.archived?
      link_to "Unarchive", unarchive_finalization_admin_finalization_path(resource), method: :post
    else
      link_to "Archive", archive_finalization_admin_finalization_path(resource), method: :post
    end
  end

  action_item :explore, only: :edit, if: proc { current_admin_user.is_admin? && (finalization.review.archived? || finalization.workspace.complete?) } do
    link_to "Explore Results", admin_finalization_finalization_explorer_path(resource)
  end

  member_action :archive_finalization, method: :post do
    resource.review.update!(archived_at: DateTime.now)
    redirect_to edit_admin_finalization_path(resource), notice: "Archived!"
  end

  member_action :unarchive_finalization, method: :post do
    resource.review.update!(archived_at: nil)
    redirect_to edit_admin_finalization_path(resource), notice: "Archive reverted!"
  end

  controller do
    def update
      super do |success, failure|
        success.html {
          redirect_to(
            edit_admin_finalization_path(resource),
            notice: "Your finalization has been saved.",
          )
        }
        failure.html {
          flash[:error] = resource.errors.full_messages.join(",")
          render "edit"
        }
      end
    end
  end

  index download_links: false, title: "Workspaces" do
    column :created_at
    column :for do |resource|
      resource.review.admin_user
    end
    column :review do |resource|
      span(resource.review.status, class: "pill #{resource.review.status}")
    end
    column :compliant?
    column :points do |resource|
      if ["archived", "finalized"].include?(resource.review.status)
        resource.review.total_points
      else
        "-"
      end
    end
    column :level do |resource|
      if ["archived", "finalized"].include?(resource.review.status)
        "#{resource.review.level[:name]} ($#{resource.review.level[:salary].to_s(:delimited)})"
      else
        "-"
      end
    end
    actions
  end

  form do |f|
    if f.object.review.archived?
      div("This review is now archived, which means the reviewee's salary has been set as per this outcome.", class: "skill_tree_hint")
    elsif f.object.workspace.complete?
      render(partial: "finalized_nag")
    else
      div("Welcome to the finalization step! This screen is designed to be used on a screen share with your peers. The attributes in purple had deviation in their scores, and make for a good place to start discussion.", class: "skill_tree_hint")
      div("When all of your peers have agreed on a final score, fill them out in the right-most column, and mark as finalized.", class: "skill_tree_hint")
      render(partial: "docs_linkout")
    end

    score_table = f.object.review.score_table

    all_reviews = [f.object.review, *f.object.review.peer_reviews]
    reviews = all_reviews.map do |r|
      {
        from: r.admin_user.email,
        reviewee?: r.admin_user.id === f.object.review.admin_user.id,
        score_trees: (r.workspace.score_trees.map do |score_tree|
          {
            tree_id: score_tree.tree_id,
            scores: (score_tree.scores.map do |score|
              {
                trait_id: score.trait_id,
                band: score.band,
                band_all_agree?: (score_table[score.trait_id][:band].uniq.size == 1),
                consistency: score.consistency,
                consistency_all_agree?: (score_table[score.trait_id][:consistency].uniq.size == 1),
              }
            end),
          }
        end),
        notes: r.workspace.notes,
      }
    end

    f.object.workspace.score_trees.each do |score_tree|
      score_tree.scores.each do |score|
        if (score_table[score.trait_id][:band].uniq.size == 1)
          score.band = score_table[score.trait_id][:band][0] if score.band.nil?
        end
        if (score_table[score.trait_id][:consistency].uniq.size == 1)
          score.consistency = score_table[score.trait_id][:consistency][0] if score.consistency.nil?
        end
      end
    end

    labelsets = f.object.workspace.score_trees.map do |st|
      st.scores.map do |score|
        {
          trait_id: score.trait_id,
          name: score.trait.name,
          needs_discussion?: ((score_table[score.trait_id][:band].uniq.size != 1) ||
                              (score_table[score.trait_id][:consistency].uniq.size != 1)),
        }
      end
    end

    div([
      render(partial: "comparitor_labels", locals: { labelsets: labelsets }),
      *(reviews.map do |r|
        render(partial: "comparitor_table", locals: { review: r })
      end),
      f.inputs(for: [:workspace, f.object.workspace], class: "inputs workspace") do |wf|
        wf.input(:display_name, input_html: { readonly: true }, wrapper_html: { class: "display mini" })
        wf.has_many :score_trees, heading: false, allow_destroy: false, new_record: false do |sf|
          sf.has_many(:scores, {
            heading: false,
            allow_destroy: false,
            new_record: false,
            class: "inline_fieldset",
          }) do |sts|
            sts.input(:band, {
              prompt: "Select a Band",
              collection: sts.object.possible_bands.map { |b| [b.titleize.capitalize, b] },
              wrapper_html: {
                class: (sts.object.possible_bands.length == 1 ? "agree" : ""),
              },
            })
            sts.input(:consistency, {
              prompt: "Select a Consistency",
              collection: sts.object.possible_consistencies.map { |c| [c.titleize.capitalize, c] },
              wrapper_html: {
                class: (sts.object.possible_consistencies.length == 1 ? "agree" : ""),
              },
            })
          end
        end

        wf.input :notes, placeholder: "As you finalize the skill tree with your peers, add final notes here.", label: false, wrapper_html: { class: "finalization_notes" }
        wf.input :status, as: :select, collection: [:draft, :complete], include_blank: false
      end,
    ], class: "comparitor_table_parent")

    unless f.object.review.archived?
      div(class: "action_buttons") do
        if f.object.workspace.complete?
          button("Unfinalize", {
            onclick: "attemptTriggerEnumChangeAndSave('select#finalization_workspace_attributes_status', 'draft')",
            type: "button",
            class: "cancel",
          })
        else
          button("Save as Draft", {
            onclick: "attemptTriggerEnumChangeAndSave('select#finalization_workspace_attributes_status', 'draft')",
            type: "button",
            class: "draft",
          })
          button("Mark as Finalized", {
            onclick: "attemptTriggerEnumChangeAndSave('select#finalization_workspace_attributes_status', 'complete')",
            type: "button",
            class: "complete",
          })
        end
      end
    end

    f.actions
  end
end
