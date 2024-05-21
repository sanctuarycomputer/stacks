ActiveAdmin.register_page "Stale Tasks" do
  menu parent: "Notion Pages"

  content title: "Stale Tasks" do
    table_for(Stacks::Notion::Task.stale, class: 'index_table') do
      column "Task", :task do |task|
        task.notion_page
      end
      column "Steward", :steward do |task|
        task.stewards.map{|p| p.dig("person", "email")}
      end
      column "Assignees", :assignees do |task|
        task.assignees.map{|p| p.dig("person", "email")}
      end
      column "Due Date", :time_in_days_since_role_last_held do |task|
        task.due_date
      end
      column "Open in Notion", :open_in_notion do |task|
        a "View in Notion ↗", href: task.notion_link, target: "_blank"
      end
    end
  end
end
