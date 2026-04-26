ActiveAdmin.register_page "Tasks" do
  menu label: "Tasks", parent: "Dashboard"

  content title: "Tasks" do
    render(partial: "tasks", locals: {
      tasks: Stacks::TaskBuilder.new.tasks,
    })
  end
end
