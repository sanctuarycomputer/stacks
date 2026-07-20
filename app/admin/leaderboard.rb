ActiveAdmin.register_page "Leaderboard" do
  menu label: "Leaderboard", priority: 20, if: proc { current_admin_user.is_admin? }

  # The global AuthorizationAdapter lets project leads through for most pages,
  # so gate this one explicitly: earnings across the whole collective are
  # admin-only.
  controller do
    before_action :require_admin!

    private

    def require_admin!
      unless current_admin_user&.is_admin?
        redirect_to admin_root_path, alert: "Admins only."
      end
    end
  end

  content title: "Leaderboard" do
    limit = Stacks::Leaderboard.sanitize_limit(params[:limit])

    render(partial: "leaderboard", locals: {
      limit: limit,
      months: Stacks::Leaderboard.call(limit: limit),
    })
  end
end
