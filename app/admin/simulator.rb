ActiveAdmin.register_page "Simulator" do
  menu if: proc { current_admin_user.email == "hugh@sanctuary.computer" },
       label: "Simulator",
       priority: 2

  content title: "Simulator" do
    render(partial: "simulator", locals: {
    })
  end
end
