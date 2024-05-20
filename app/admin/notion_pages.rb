ActiveAdmin.register NotionPage do
  config.filters = true
  config.paginate = true
  config.per_page = [200, 100, 50]
  actions :index, :show

  scope :milestones, default: true
  scope :biz_plan_2024_milestones

  filter :page_title, filters: [:cont, :eq]

  index download_links: false do
    column :page_title
    column :status
    column :progress do |r|
      "#{(r.data.dig("properties", "Progress", "formula", "number") * 100).round(2)}%"
    end
    actions
  end

  show do
    if notion_page.notion_parent_id == Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:MILESTONES])
      tasks = NotionPage.where(notion_id: notion_page.data["properties"]["Tasks"]["relation"].map{|t| t["id"]})
      by_status_history = tasks.map(&:status_history)

      tasks_by_status = tasks.reduce({
        todo: [],
        completed: [],
        let_go: [],
        total_complexity: 0,
        earliest_completed: Date.today,
        latest_completed: Date.today,
        deadline: Date.today + 3.months # todo
      }) do |acc, task|
        due_date = task.data.dig("properties", "✳️ Due Date 🗓", "date", "end") || task.data.dig("properties", "✳️ Due Date 🗓", "date", "start")
        t = {
          task: task,
          complexity: 1,
          date: task.status_history.last[:changed_at],
          due_date: due_date.present? ? Date.parse(due_date) : nil
        }

        if task.status.downcase.include?("let go")
          acc[:let_go] = [*acc[:let_go], t].sort_by{|t| t[:date] }
        elsif task.status.downcase.include?("done")
          acc[:earliest_completed] = t[:date] if t[:date] < acc[:earliest_completed]
          acc[:latest_completed] = t[:date] if t[:date] > acc[:latest_completed]

          acc[:total_complexity] += t[:complexity]
          acc[:completed] = [*acc[:completed], t].sort_by{|t| t[:date] }
        else
          acc[:total_complexity] += t[:complexity]
          acc[:todo] = [*acc[:todo], t].sort_by{|t| t[:date] }
        end

        acc
      end

      burnup_data = {
        type: 'line',
        data: {
          datasets: [{
            label: "Burnup",
            backgroundColor: Stacks::Utils::COLORS[0], # color of dots
            borderColor: Stacks::Utils::COLORS[5], # color of line
            #pointRadius: 0,
            data: []
          }, {
            label: "Target Velocity",
            borderDash: [5, 5],
            pointRadius: 0,
            data: [{
              x: tasks_by_status[:earliest_completed],
              y: 0
            }, {
              x: tasks_by_status[:deadline],
              y: tasks_by_status[:total_complexity]
            }]
          }]
        },
        options: {
          scales: {
            x: {
              type: 'time',
              min: tasks_by_status[:earliest_completed],
              max: [tasks_by_status[:deadline], tasks_by_status[:latest_completed]].max,
              time: {
                unit: 'month'
              }
            },
            y: {
              min: 0,
              max: tasks_by_status[:total_complexity]
            }
          }
        }
      }

      tasks_by_status[:completed].each do |t|
        prev_datapoints = burnup_data[:data][:datasets].first[:data]
        running_complexity = prev_datapoints.last.try(:dig, :y) || 0
        burnup_data[:data][:datasets].first[:data] = [*prev_datapoints, {
          x: t[:date].iso8601,
          y: running_complexity + t[:complexity],
          label: "foo"
        }]
      end

      render 'milestones_show', {
        milestone: notion_page,
        tasks_by_status: tasks_by_status,
        burnup_data: burnup_data
      }
    else
      h1 "Not sure how to render this notion page"
    end
  end

end
