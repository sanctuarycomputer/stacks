class Stacks::Notion::Task < Stacks::Notion::Base
  class << self
    def all
      NotionPage.where(
        notion_parent_type: "database_id",
        notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:TASKS])
      ).map(&:as_task)
    end

    def stale
      Stacks::Notion::Task.all.select do |task|
        task.in_flight? && task.overdue?
      end.sort_by do |task|
        task.due_date
      end
    end
  end

  def stewards
    get_prop_value("steward")
  end

  def assignees
    get_prop_value("assignees")
  end

  def status
    get_prop_value("status").dig("name")
  end

  def done?
    status.downcase.include?("done")
  end

  def let_go?
    status.downcase.include?("let go")
  end

  def in_flight?
    !done? && !let_go?
  end

  def overdue?
    due_date && due_date < Date.today
  end

  def due_date
    @_due_date ||= (
      raw_due_date = get_prop_value("due date").dig("end") || get_prop_value("due date").dig("start")
      raw_due_date ? Date.parse(raw_due_date) : nil
    )
  end
end

