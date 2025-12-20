ActiveAdmin.register_page "Skill Trees" do
  menu priority: 3

  controller do
    before_action do |_|
      redirect_to admin_reviews_path
    end
  end
end