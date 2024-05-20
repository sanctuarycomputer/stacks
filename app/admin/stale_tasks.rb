ActiveAdmin.register_page "Stale Tasks" do
  menu parent: "Notion Pages"

  content title: "Stale Tasks" do
    table_for(NotionPage.stale_tasks, class: 'index_table') do
      column "Task", :task do |task|
        task
      end
      column "Steward", :steward do |task|
        key = task.data.dig("properties").keys.find{|k| k.downcase.include?("steward")}
        people = task.data.dig("properties", key)
        people.dig("people").map{|p| p.dig("person", "email")}
      end
      column "Assignees", :assignees do |task|
        key = task.data.dig("properties").keys.find{|k| k.downcase.include?("assignees")}
        people = task.data.dig("properties", key)
        people.dig("people").map{|p| p.dig("person", "email")}
      end
      column "Due Date", :time_in_days_since_role_last_held do |task|
        due_date = task.data.dig("properties", "✳️ Due Date 🗓", "date", "end") || task.data.dig("properties", "✳️ Due Date 🗓", "date", "start")
        Date.parse(due_date).strftime("%B %d, %Y")
      end
      column "Open in Notion", :open_in_notion do |task|
        a "View in Notion ↗", href: task.notion_link, target: "_blank"
      end
    end

  end
end
