class Stacks::Notion::Task < Stacks::Notion::Base
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

