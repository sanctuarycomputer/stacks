ActiveAdmin.register_page "Availability" do
  content title: "Availability" do
    allocations, errors = Stacks::Availability.load_allocations_from_notion

    # I should be able to filter by studio
    # I should see people even if they're not in the availbility boards
    # I should see errors (missing capacity, missing dates, missing assign)

    render(partial: "availability", locals: {
      errors: errors,
      changes: Stacks::Availability.discover_changes!(allocations),
      today: Stacks::Availability.allocations_on_date(allocations, Date.today)
    })
  end
end
