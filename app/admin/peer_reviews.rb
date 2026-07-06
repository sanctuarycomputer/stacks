ActiveAdmin.register PeerReview do
  menu label: "Review Requests", parent: "Skill Trees", priority: 2

  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index
  scope_to :current_admin_user

  action_item :go_to_workspace, only: [:show, :edit] do
    link_to "Go to Workspace →", edit_admin_workspace_path(resource.workspace)
  end

  index download_links: false, title: "Review Requests" do
    render(partial: "docs_linkout")

    column :created_at
    column :for do |resource|
      resource.review.admin_user
    end
    column :workspace_status do |resource|
      span(resource.status, class: "pill #{resource.status}")
    end
    actions defaults: false do |resource|
      link_to "Go to Workspace →", edit_admin_workspace_path(resource.workspace) if resource.workspace.present?
    end
  end
end
