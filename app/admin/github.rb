ActiveAdmin.register_page "Github & Zenhub" do
  controller do
    before_action do |_|
      redirect_to admin_github_repos_path
    end
  end
end
