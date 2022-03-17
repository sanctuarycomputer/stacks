ActiveAdmin.register_page "Availability" do
  menu parent: "Team"

  content title: "Availability" do
    allocations, errors = Stacks::Availability.load_allocations_from_notion
    render(partial: "availability", locals: {
      errors: errors,
      changes: Stacks::Availability.discover_changes!(allocations),
      today: Stacks::Availability.allocations_on_date(allocations, Date.today)
    })
  end
end
