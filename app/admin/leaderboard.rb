ActiveAdmin.register_page "Leaderboard" do
  # Nested under the Money tab, and hidden from the nav for anyone who isn't
  # an admin. Menu visibility is presentation, not access control —
  # require_admin! below is what actually blocks a hand-typed URL.
  menu label: "Leaderboard",
       parent: "Money",
       priority: 20,
       if: proc { current_admin_user&.is_admin? }

  # The global AuthorizationAdapter lets project leads through for most pages,
  # so gate this one explicitly: earnings across the whole collective are
  # admin-only. Applies to every format, including the CSV download.
  controller do
    before_action :require_admin!

    # ActiveAdmin's `csv do ... end` DSL is defined on ResourceDSL and needs an
    # ActiveRecord-backed collection, so a register_page can't use it. We get
    # the same convention by hand: the index responds to .csv, which keeps the
    # familiar /admin/leaderboard.csv URL and lets the standard
    # "Download: CSV" footer link work with plain url_for.
    def index
      return super() unless request.format.csv?

      limit = Stacks::Leaderboard.sanitize_limit(params[:limit])

      send_data Stacks::Leaderboard.to_csv(limit: limit),
        type: "text/csv; charset=utf-8",
        disposition: %(attachment; filename="leaderboard-top-#{limit}-#{Date.today.iso8601}.csv")
    end

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
