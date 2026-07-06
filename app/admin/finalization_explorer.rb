ActiveAdmin.register_page "Finalization Explorer" do
  belongs_to :finalization

  content title: proc { I18n.t("active_admin.finalization_explorer") } do
    render(partial: "finalization_explorer", locals: {
      finalization: Finalization.find(params[:finalization_id])
    })
  end
end
