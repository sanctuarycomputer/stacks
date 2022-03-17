ActiveAdmin.register Review do
  menu label: "My Reviews", parent: "Skill Trees", priority: 1
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  scope_to :current_admin_user
  actions :index, :new, :edit, :update, :create, :destroy

  permit_params :admin_user_id,
    peer_reviews_attributes: [:id, :admin_user_id, :review_id, :_destroy, :_edit],
    review_trees_attributes: [:id, :review_id, :tree_id, :_destroy, :_edit]

  action_item :go_to_workspace, only: [:show, :edit] do
    link_to "Go to Workspace →", edit_admin_workspace_path(resource.workspace) if resource.workspace.present?
  end

  member_action :finalize do
    if resource.workspace.complete?
      if resource.peer_reviews.map(&:workspace).map(&:complete?).all?
        redirect_to edit_admin_finalization_path(resource.finalization)
      else
        redirect_to admin_reviews_path, alert: "Please ask your peer reviewers to mark the workspace as complete."
      end
    else
      redirect_to admin_reviews_path, alert: "Please mark your workspace as complete before finalizing."
    end
  end

  index download_links: false do
    render(partial: "docs_linkout")

    column :created_at
    column :peer_reviewers do |resource|
      resource.peer_reviews.map do |peer_review|
        span([
          a(peer_review.admin_user.email, { href: admin_admin_user_path(peer_review.admin_user) }),
          span(peer_review.workspace.status, class: "pill #{peer_review.workspace.status}"),
        ], class: "peer_reviewer_pill")
      end
      nil
    end
    column :workspace_status do |resource|
      span(resource.status, class: "pill #{resource.status}")
    end
    actions do |resource|
      item "Go to Workspace →", edit_admin_workspace_path(resource.workspace), class: "member_link"
      item "Finalize!", finalize_admin_review_path(resource), class: "member_link"
    end
  end

  controller do
    def new
      build_resource
      # Start with at least two peer review
      resource.peer_reviews << PeerReview.new
      resource.peer_reviews << PeerReview.new

      # Start with the three trees
      resource.review_trees << ReviewTree.new({
        tree: Tree.find_by(name: "Individual Contributor"),
      })
      resource.review_trees << ReviewTree.new({
        tree: resource.admin_user.previous_tree_used,
      })
      resource.review_trees << ReviewTree.new({
        tree: Tree.find_by(name: "Studio Impact"),
      })
      new!
    end
  end

  form do |f|
    div("Please select a craft for your self review, and elect at least 2x peer reviewers. Your peer review request will show up on their dashboard!", class: "skill_tree_hint")
    render(partial: "docs_linkout")

    f.object.admin_user = current_admin_user

    f.inputs(class: "admin_inputs") do
      h1 "Peers"
      f.has_many :peer_reviews, heading: false, allow_destroy: true do |a|
        a.object.review = f.object
        a.input :admin_user, label: "Request a peer review from:", prompt: "Select a Peer", collection: AdminUser.active.where.not(id: current_admin_user.id)
      end
    end

    f.inputs(class: "admin_inputs") do
      h1 "Trees"
      f.has_many :review_trees, heading: false, new_record: false do |a|
        a.object.review = f.object
        a.input(:tree, {
          label: "Category",
          prompt: "Select a Craft",
          collection: a.object.possible_trees,
          wrapper_html: {
            class: (a.object.can_change_tree ? "agree" : ""),
          },
        })
      end
    end

    f.actions
  end
end
