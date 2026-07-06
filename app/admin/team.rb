ActiveAdmin.register_page "Team" do
  controller do
    before_action do |_|
      redirect_to admin_admin_users_path
    end
  end
end
