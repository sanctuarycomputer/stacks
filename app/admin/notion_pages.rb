ActiveAdmin.register NotionPage do
  config.filters = true
  config.paginate = true
  actions :index, :show

  scope :milestones, default: true
  filter :page_title_eq, as: :string, label: "Page Title"

  index download_links: false do
    column :page_title
    column :status
    actions
  end

  show do
    if notion_page.notion_parent_id == Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:MILESTONES])
      tasks = NotionPage.where(notion_id: notion_page.data["properties"]["Tasks"]["relation"].map{|t| t["id"]})
      render 'milestones_show', {
        milestone: notion_page,
        tasks: tasks
      }
    else
      h1 "Not sure how to render this notion page"
    end
  end

end
