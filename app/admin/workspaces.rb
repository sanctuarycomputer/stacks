ActiveAdmin.register Workspace do
  menu false
  config.breadcrumb = false
  actions :index, :edit, :update
  permit_params :status, :notes,
    score_trees_attributes: [
      :id,
      :_edit,
      scores_attributes: [
        :id,
        :band,
        :consistency,
        :_edit,
      ]
    ]

  controller do
    def update
      super do |success, failure|
        success.html {
          redirect_to(
            edit_admin_workspace_path(resource),
            notice: "Your workspace has been saved."
          )
        }
        failure.html {
          flash[:error] = resource.errors.full_messages.join(',')
          render 'edit'
        }
      end
    end
  end

  action_item :go_to_workspace, only: :edit do
    if resource.reviewable_type == "PeerReview"
      link_to 'Back', admin_peer_reviews_path
    else
      link_to 'Back', admin_reviews_path
    end
  end

  form do |f|
    if f.object.review.archived?
      div("This review has been archived, and the reviewee's salary updated. This page is here for future reference.", class: "skill_tree_hint")
    elsif f.object.review.finalized?
      div("This review has already been finalized. If you need to change this workspace, the reviewee needs to unfinalize their finalization.", class: "skill_tree_hint")
    else
      div("You're editing a skill tree evaluation for #{f.object.reviewable.reviewee.email}. Take your time and work through it - you can save it as a draft if you need more time. Once you're done, mark it as complete, and schedule some time for an in-person peer review to finalize it.", class: "skill_tree_hint")
    end

    f.has_many :score_trees, heading: false, allow_destroy: false, new_record: false do |sf|
      sf.input(:display_name, input_html: { readonly: true }, wrapper_html: { class: "display" })
      sf.has_many(:scores, {
        heading: false,
        allow_destroy: false,
        new_record: false,
        class: "inline_fieldset"
      }) do |sts|
        sts.input(:display_name, input_html: { readonly: true })
        sts.input(:band, {
          prompt: "Select a Band",
          wrapper_html: { class: (f.object.review.archived? || f.object.review.finalized?) ? "agree" : "" }
        })
        sts.input(:consistency, {
          prompt: "Select a Consistency",
          wrapper_html: { class: (f.object.review.archived? || f.object.review.finalized?) ? "agree" : "" }
        })
      end
    end

    h1 "Notes & Talking Points"
    div("When you're done with this review, you'll setup a call to finalize the skill tree. This field is helpful for recording notes that can help that conversation along.", class: "skill_tree_hint")
    f.input :notes, placeholder: "As you fill out the skill tree, add notes that you think are relevant here.", label: false

    # Status Toggle
    f.input :status, as: :select, collection: [:draft, :complete], include_blank: false
    unless (f.object.review.archived? || f.object.review.finalized?)
      div(class: "action_buttons") do
        if f.object.complete?
          button "Uncomplete!", onclick: "attemptTriggerEnumChangeAndSave('select#workspace_status', 'draft')", type: "button", class: "cancel"
        else
          button "Save as Draft", onclick: "attemptTriggerEnumChangeAndSave('select#workspace_status', 'draft')", type: "button", class: "draft"
          button "Mark as Complete", onclick: "attemptTriggerEnumChangeAndSave('select#workspace_status', 'complete')", type: "button", class: "complete"
        end
      end
      f.actions
    end
  end
end
