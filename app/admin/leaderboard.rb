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
    months = Stacks::Leaderboard.call(limit: limit)

    rule = "1px solid #e4dcc8"
    ledger_bg = "#fffdf7"
    header_bg = "#f4ecda"
    ink = "#3a3222"
    muted = "#8a7f66"
    numerals = "font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-variant-numeric: tabular-nums;"

    div style: "max-width: 780px; color: #{ink};" do
      div style: "margin-bottom: 1.5em;" do
        para style: "margin: 0 0 0.4em 0; color: #{muted};" do
          "Top #{limit} earners per month, by aggregate contributor payouts across all ledgers. " \
          "Trueups are excluded — they top leadership roles up to these averages, so counting " \
          "them would double back on the benchmark."
        end
        div style: "color: #{muted};" do
          span "Show top: "
          [3, 5, 10, 20].each do |n|
            selected = (n == limit)
            span style: "margin-right: 0.5em;" do
              if selected
                span n.to_s, style: "font-weight: 700; color: #{ink};"
              else
                link_to n.to_s, admin_leaderboard_path(limit: n)
              end
            end
          end
        end
      end

      if months.empty?
        div style: "padding: 1em; background: #{ledger_bg}; border: #{rule};" do
          para "No contributor payouts recorded yet."
        end
      end

      months.each do |group|
        div style: "margin-bottom: 1.5em; background: #{ledger_bg}; border: #{rule};" do
          div style: "display: flex; justify-content: space-between; align-items: baseline; " \
                     "padding: 0.6em 0.9em; background: #{header_bg}; border-bottom: #{rule};" do
            span group.start_of_month.strftime("%B %Y"), style: "font-weight: 700; letter-spacing: 0.02em;"
            span number_to_currency(group.total), style: "font-weight: 700; #{numerals}"
          end

          table style: "width: 100%; border-collapse: collapse;" do
            group.entries.each do |entry|
              tr style: "border-bottom: #{rule};" do
                td entry.rank.to_s,
                  style: "width: 2.5em; padding: 0.55em 0.9em; color: #{muted}; #{numerals}"
                td entry.display_name,
                  style: "padding: 0.55em 0.9em;"
                td number_to_currency(entry.amount),
                  style: "padding: 0.55em 0.9em; text-align: right; white-space: nowrap; #{numerals}"
              end
            end
          end
        end
      end
    end
  end
end
