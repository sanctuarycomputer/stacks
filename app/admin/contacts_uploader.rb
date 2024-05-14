ActiveAdmin.register_page "Contacts Uploader" do
  menu parent: "Contacts"

  content title: "Contacts Uploader" do
    render(partial: "show", locals: {
    })
  end
end
