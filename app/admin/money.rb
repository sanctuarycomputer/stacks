ActiveAdmin.register_page "Money" do
  controller do
    before_action do |_|
      redirect_to admin_invoice_passes_path
    end
  end
end
