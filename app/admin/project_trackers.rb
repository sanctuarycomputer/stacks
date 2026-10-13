ActiveAdmin.register ProjectTracker do
  menu label: "Projects", priority: 2
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index, :new, :show, :edit, :update, :create, :destroy
  config.current_filters = false

  scope :in_progress, default: true
  scope :dormant
  scope :complete
  # Gated capsules have all four statuses set, so the SQL `complete` scope files
  # them under Complete while their own page reads Pending. Give them a home.
  # show_count: false is deliberate. ActiveAdmin computes every scope's count on
  # every index render, and this resource sets config.paginate = false, so a
  # counted Ruby-filtered scope would scan all completed trackers on each load of
  # the default In Progress tab.
  scope :needs_capsule_sign_off, show_count: false do |scope|
    ids = ProjectTracker.complete.includes(project_capsule: :project_satisfaction_survey)
      .select { |pt| pt.project_capsule&.complete_but_for_admin_sign_off? }.map(&:id)
    scope.where(id: ids)
  end
  # The trackers whose Flags pill on this index is not blank: the ids come
  # from the same count the pill prints (Stacks::ProjectLog.flag_counts), so
  # the two cannot disagree. show_count: false for the reason above: it is read
  # only when this tab is opened, never on a load of another tab. Empty,
  # never an error, before the first sync or when the log's rows cannot be read.
  scope "Has Flags", :has_flags, show_count: false do |scope|
    ids =
      begin
        Stacks::ProjectLog.flagged_tracker_ids
      rescue StandardError => e
        Rails.logger.error("[project log] flagged trackers could not be read: #{e.class}: #{e.message}")
        []
      end
    scope.where(id: ids)
  end

  permit_params :name,
    :billing_model,
    :budget_low_end,
    :budget_high_end,
    :monthly_budget_low_end,
    :monthly_budget_high_end,
    :target_profit_margin,
    :target_free_hours_percent,
    :notes,
    :runn_project_id,
    notion_project_ids: [],
    adhoc_invoice_trackers_attributes: [
      :id,
      :qbo_invoice_id,
      :_destroy,
      :_edit
    ],
    project_tracker_links_attributes: [
      :id,
      :name,
      :url,
      :link_type,
      :project_tracker_id,
      :_destroy,
      :_edit
    ],
    project_tracker_forecast_projects_attributes: [
      :id,
      :forecast_project_id,
      :_destroy,
      :_edit
    ],
    commissions_attributes: [
      :id,
      :type,
      :contributor_id,
      :rate,
      :notes,
      :_destroy,
      :_edit,
    ]

  controller do
    # ProjectTracker's nested form supports destroying adhoc_invoice_trackers.
    # InvoiceTracker has_many :contributor_payouts, dependent: :destroy, so
    # the cascade hits ContributorPayout#before_destroy → SyncsAsQboBill's
    # paid-bill guard. Catch it with a flash instead of a 500 — operator can
    # void the QBO BillPayment(s) first and retry.
    rescue_from SyncsAsQboBill::PaidQboBillError do |e|
      Rails.logger.error("[project_tracker_destroy_cascade] #{e.message}")
      redirect_back fallback_location: admin_project_trackers_path,
        alert: "Cannot save: a contributor payout linked to this tracker has a paid QBO bill. Void the BillPayment in QBO first, then retry."
    end

    def new
      build_resource
      resource.project_tracker_links << ProjectTrackerLink.new({
        name: "MSA",
        link_type: :msa
      })
      resource.project_tracker_links << ProjectTrackerLink.new({
        name: "SOW/PD",
        link_type: :sow
      })
      new!
    end

    def scoped_collection
      super.includes(
        :runn_project,
        { forecast_projects: { forecast_client: :enterprise_forecast_client } },
        { project_capsule: :project_satisfaction_survey },
        { project_tracker_forecast_projects: :forecast_project },
        { adhoc_invoice_trackers: :qbo_invoice },
        { account_lead_periods: :admin_user },
        { project_lead_periods: :admin_user }
      )
    end

    # Arbre column blocks don't see controller ivars (a bare @ivar reads the
    # Arbre component's own, nil ivar) — but they DO delegate method calls to
    # the controller's helpers. Expose the ship map as a helper method, same
    # pattern as admin_users.rb#last_month_utilization_by_email.
    helper_method :last_weekly_ships_by_tracker_id
    def last_weekly_ships_by_tracker_id
      @last_ships_by_tracker_id || {}
    end

    # The Notion Projects pages the rendered trackers point at, by Notion id,
    # loaded once for the whole table. A page removed from Notion is absent.
    helper_method :notion_project_pages_by_notion_id
    def notion_project_pages_by_notion_id
      @notion_project_pages_by_notion_id || {}
    end

    # How many flags each rendered tracker's log shows (Stacks::ProjectLog),
    # by tracker id, counted once for the whole table. A tracker with none is
    # absent, and so is every tracker when the log's rows cannot be read.
    helper_method :log_flag_counts_by_tracker_id
    def log_flag_counts_by_tracker_id
      @log_flag_counts_by_tracker_id || {}
    end

    def collection
      c = super
      if action_name == "index" && !@_preloaded_for_render
        arr = c.to_a
        ProjectTracker.preload_for_render(arr)
        @last_ships_by_tracker_id = WeeklyShip.includes(:document).latest_by_tracker(arr.map(&:id))
        notion_ids = arr.flat_map { |pt| Array(pt.notion_project_ids) }.uniq
        @notion_project_pages_by_notion_id =
          notion_ids.empty? ? {} : NotionPage.projects.where(notion_id: notion_ids).index_by(&:notion_id)
        # The index is worth more than its newest column: when the log's rows
        # cannot be read (the sync's columns are missing, say) it stays blank.
        @log_flag_counts_by_tracker_id =
          begin
            Stacks::ProjectLog.flag_counts(arr)
          rescue StandardError => e
            Rails.logger.error("[project log] flag counts could not be read: #{e.class}: #{e.message}")
            {}
          end
        @_preloaded_for_render = true
        # Group by account lead on the Active and Dormant tabs (and on the
        # default unfiltered view). Within each lead, fall back to the
        # config-level `created_at DESC` tiebreaker. Trackers with no current
        # account lead sort last.
        if %w[in_progress dormant].include?(params["scope"]) || params["scope"].blank?
          sorted = arr.sort_by do |pt|
            first_lead = pt.current_account_leads.map { |au| au&.name.to_s }.reject(&:empty?).sort.first
            [first_lead.nil? ? 1 : 0, (first_lead || "").downcase, -pt.created_at.to_i]
          end
          # `paginated_collection` (AA view helper) requires a Kaminari-style
          # page/per interface even when `config.paginate = false`. A bare
          # Array doesn't qualify, so wrap with Kaminari.paginate_array.
          @_index_array = Kaminari.paginate_array(sorted).page(1).per(sorted.size.nonzero? || 1)
        end
      end
      @_index_array || c
    end
  end

  index download_links: false, title: "Projects" do
    column :considered_successful?

    if params["scope"] == "complete"
      column :project_satisfaction_survey do |pt|
        survey = pt&.project_capsule&.project_satisfaction_survey
        if survey&.closed_at&.present?
          raw = survey.score || survey.overall_rating_from_question_responses
          score = raw.nil? ? nil : raw.to_f.round(1)
          if score.nil?
            span("No responses", class: "pill error")
          else
            pill_class =
              if score >= 4.5
                "exceptional"
              elsif score >= 3.5
                "healthy"
              elsif score >= 2.5
                "at_risk"
              else
                "failing"
              end

            span("#{score} / 5", class: "pill #{pill_class}")
          end
        else
          "No survey"
        end
      end
      column :last_recorded_assignment do |pt|
        pt.last_recorded_assignment_end_date
      end
    end

    column :name

    column :hours do |resource|
      free_hours = resource.total_free_hours
      total_hours = resource.total_hours
      free_hours_percentage = resource.free_hours_ratio * 100

      pill_class =
        if free_hours_percentage == 0
          "exceptional"
        elsif free_hours_percentage < 1
          "healthy"
        elsif free_hours_percentage < 5
          "at_risk"
        else
          "failing"
        end

      div([
        span(class: "pill #{pill_class}") do
          span(class: "split") do
            [strong("#{total_hours.round} hrs,"), span("#{free_hours.round} free")]
          end
        end,
        para(class: "okr_hint") do
          "#{free_hours_percentage.round(1)}% hrs billed at $0p/h"
        end
      ])
    end
    column :budget_status do |resource|
      span(resource.status.to_s.humanize.capitalize, class: "pill #{resource.status}")
    end
    column :work_status do |resource|
      span(resource.work_status.to_s.humanize.capitalize, class: "pill #{resource.work_status}")
    end

    # Asked once, not per row: whether a reader may open a ship's page depends
    # only on who they are (project-scoped lead grants cannot).
    can_open_ships = authorized?(:read, WeeklyShip)
    column "Last Ship" do |pt|
      # Completed projects aren't expected to ship — show a muted dash.
      if params[:scope] == "complete"
        span "—", style: "opacity: 0.4;"
        next
      end
      # Anchored to the project's last recorded Forecast hour, not the
      # calendar — a paused project whose ships kept pace stays green.
      ship = last_weekly_ships_by_tracker_id[pt.id]
      staleness = ProjectTracker.ship_staleness(ship, anchor: pt.last_recorded_forecast_date)
      if ship.nil?
        if pt.internal_client?
          # Our own companies don't send client-facing weekly ships.
          span "—", style: "opacity: 0.4;"
        else
          span "No ships yet", class: "pill", style: "background-color: #1a1a1a; color: #fff;"
        end
      else
        # Stars first, then when and who. The colour is the worse of staleness
        # and grade (WeeklyShip.pill_class); an ungraded ship has no stars.
        grade = ship.grade
        stars = grade&.dig("stars")
        # First name, or the part of the address before the @ when there is no name.
        who = ship.sender&.split(/[\s@]/)&.first
        when_and_who = "#{time_ago_in_words(ship.sent_at)} ago#{" by #{who}" if who}"
        label = [(WeeklyShip.stars_label(stars) if grade), when_and_who].compact.join(" · ")
        # font-size: the global `a` rule would otherwise size the pill's text at 18px.
        link_style = "text-decoration: none; color: inherit; font-size: inherit;"
        # Arbre `a`, not block-form link_to — Rails' capture doesn't see Arbre
        # elements, which renders the content OUTSIDE an empty anchor.
        # The link's title also says why the pill is orange or red: it covers
        # the whole pill, so the pill's own title alone would rarely show.
        reason = WeeklyShip.pill_reason(staleness: staleness, stars: stars)
        span(class: WeeklyShip.pill_class(staleness: staleness, stars: stars), title: reason) do
          if can_open_ships
            # One link, to the coaching page. The email is a click away from there.
            a(label, href: admin_weekly_ship_path(ship), style: link_style,
              title: [grade && grade["summary"].presence, "Open the coaching for this ship.", reason].compact.join(" "))
          elsif (url = ship.document&.google_groups_permalink)
            # A reader who cannot open the coaching page still gets the email.
            a("#{label} ↗", href: url, target: "_blank", rel: "noopener",
              title: ["Open the email.", reason].compact.join(" "), style: link_style)
          else
            text_node label
          end
        end
      end
    end

    # How many flags the project's log shows right now, linking to it. What
    # is a flag is Notion's call (Stacks::ProjectLog). Blank when there are none.
    column "Flags" do |pt|
      count = log_flag_counts_by_tracker_id[pt.id].to_i
      label = "#{count} #{count == 1 ? 'Flag' : 'Flags'}"
      a(label, href: admin_project_tracker_log_path(pt), class: "pill error log-flag-count", style: "text-decoration: none; white-space: nowrap;",
        title: "#{label} in the project log") if count > 0
    end

    column :forecast_projects do |resource|
      if resource.forecast_projects.any?
        div(
          resource.forecast_projects.map do |fp|
            a("#{fp.display_name} ↗", { href: fp.link, target: "_blank", class: "block", style: "white-space:nowrap" })
          end
        )
      else
        span("No Forecast Project/s Connected", class: "pill error")
      end
    end

    column "Account Lead (AL)", :account_leads do |resource|
      if resource.current_account_leads.any?
        resource.current_account_leads
      else
        span("No Account Lead", class: "pill error")
      end
    end
    column "Project Lead (PL)", :project_leads do |resource|
      if resource.current_project_leads.any?
        resource.current_project_leads
      else
        span("No Project Lead", class: "pill error")
      end
    end

    column "Runn.io Project", :runn_project do |resource|
      if resource.runn_project.present?
        a("#{resource.runn_project.name} ↗", { href: resource.runn_project.link, target: "_blank", class: "block", style: "white-space:nowrap" })
      else
        span("No Runn.io Project Connected", class: "pill error")
      end
    end

    # One line per channel, in channel-id order. The name is plain text from
    # Twist or from whoever typed it: Arbre escapes it, so never html_safe.
    column "Twist" do |pt|
      links = pt.project_tracker_links.select(&:twist_channel_id).sort_by(&:twist_channel_id)
      if links.empty?
        if params[:scope] == "complete" || pt.internal_client?
          # Finished and internal projects aren't expected to have a channel.
          span "—", style: "opacity: 0.4;"
        else
          span("No Twist Channel", class: "pill error")
        end
        next
      end
      unreadable = Array(pt.twist_channels_inaccessible)
      div do
        links.each do |link|
          a("#{link.name.presence || ProjectTracker::TWIST_LINK_PLACEHOLDER_NAME} ↗", href: link.url, target: "_blank", class: "block", style: "white-space:nowrap")
          # Stacksbot can only file what it sees in a channel it belongs to.
          span("Stacksbot not invited", class: "pill error") if unreadable.include?(link.twist_channel_id)
        end
      end
    end

    # One line per chosen page, in the order they were chosen.
    column "Notion" do |pt|
      ids = Array(pt.notion_project_ids).reject(&:blank?)
      if ids.empty?
        if params[:scope] == "complete" || pt.internal_client?
          span "—", style: "opacity: 0.4;"
        else
          span("No Notion Project", class: "pill error")
        end
        next
      end
      pages = notion_project_pages_by_notion_id
      div do
        ids.each do |id|
          if (page = pages[id])
            a("#{page.as_project.title} ↗", href: page.notion_link, target: "_blank", class: "block", style: "white-space:nowrap")
          else
            span("Removed from Notion", class: "pill error")
          end
        end
      end
    end

    actions
  end

  action_item :mark_as_complete, only: :show do
    if resource.work_completed_at.present?
      link_to "Unmark as Work Complete", uncomplete_work_admin_project_tracker_path(resource), method: :post
    else
      link_to "Mark as Work Complete", complete_work_admin_project_tracker_path(resource), method: :post
    end
  end

  action_item :edit_account_leads, only: [:show, :edit] do
    link_to "Edit Account Lead", admin_project_tracker_account_lead_periods_path(resource)
  end

  action_item :edit_project_leads, only: [:show, :edit] do
    link_to "Edit Project Lead", admin_project_tracker_project_lead_periods_path(resource)
  end

  # Shown on any project tracker that doesn't have a linked Runn project
  # yet. The action handler matches the tracker's forecast_client to a
  # Runn client by exact (case-insensitive, trimmed) name — if no client
  # with that name exists in Runn, the admin gets a flash error telling
  # them to either create the Runn client first or rename to match.
  action_item :create_runn_project, only: [:show, :edit] do
    next if resource.runn_project.present?
    link_to "Create Runn Project ↗", create_runn_project_admin_project_tracker_path(resource), method: :post
  end

  member_action :create_runn_project, method: :post do
    if resource.runn_project.present?
      redirect_to admin_project_tracker_path(resource), alert: "This project tracker is already linked to a Runn project."
      next
    end

    fc = resource.forecast_projects.first&.forecast_client
    if fc.nil?
      redirect_to admin_project_tracker_path(resource), alert: "This project tracker has no Forecast client to match against."
      next
    end

    begin
      runn = Stacks::Runn.new
      target_name = fc.name.to_s.strip.downcase
      match = runn.get_clients.find do |c|
        next if c["isArchived"]
        c["name"].to_s.strip.downcase == target_name
      end

      if match.nil?
        redirect_to admin_project_tracker_path(resource),
          alert: "Couldn't find an active Runn client named #{fc.name.inspect}. Create it in Runn first (or rename so the names match), then try again."
        next
      end

      created = runn.create_project(resource.name, match["id"])

      # External API call done — the project exists in Runn. Wrap only the
      # local DB writes in a transaction so we don't end up with a local
      # RunnProject row that isn't linked to the project tracker (which
      # would cause the next click to create a DUPLICATE Runn project).
      # Don't put the API call inside the transaction — it'd hold a DB
      # connection open for the round-trip.
      rp = nil
      ActiveRecord::Base.transaction do
        rp = RunnProject.create!(
          runn_id: created["id"],
          name: created["name"],
          is_template: created["isTemplate"],
          is_archived: created["isArchived"],
          is_confirmed: created["isConfirmed"],
          pricing_model: created["pricingModel"],
          rate_type: created["rateType"],
          budget: created["budget"],
          expenses_budget: created["expensesBudget"],
          data: created,
        )
        resource.update!(runn_project: rp)
      end
      redirect_to admin_project_tracker_path(resource), notice: "Created Runn project ##{rp.runn_id} (#{rp.name}) and linked it."
    rescue => e
      redirect_to admin_project_tracker_path(resource),
        alert: "Failed to create Runn project: #{e.message.to_s.slice(0, 200)}"
    end
  end

  member_action :complete_work, method: :post do
    resource.update_column(:work_completed_at, DateTime.now)
    resource.ensure_project_capsule_exists!
    redirect_to admin_project_tracker_path(resource), notice: "Project marked as complete."
  end

  member_action :uncomplete_work, method: :post do
    resource.update_column(:work_completed_at, nil)
    resource.ensure_project_capsule_exists!
    redirect_to admin_project_tracker_path(resource), notice: "Project unmarked as complete."
  end

  show do
    accounting_method = session[:accounting_method] || "cash"

    start_date =
      resource.first_recorded_assignment_start_date&.iso8601 || DateTime.now.iso8601
    end_date =
      resource.last_recorded_assignment_end_date&.iso8601 || DateTime.now.iso8601

    # Assembled by the service (shared with Mcp::GetProjectBurnupTool) — the
    # seed point uses the same first-assignment-date fallback as start_date
    # above, so the chart's x-axis min and the series origin still agree.
    # (:skipped_invoices — unsynced QBO invoice mirrors — is intentionally
    # ignored here; the chart simply omits them.)
    income_data = ProjectTrackers::IncomeSeries.call(resource)

    latest_timestamp =
      income_data[:income].reduce(end_date) do |acc, datapoint|
        next datapoint[:x] if Date.parse(acc) < Date.parse(datapoint[:x])
        acc
      end

    burnup_data = {
      type: 'line',
      data: {
        datasets: []
      },
      options: {
        scales: {
          x: {
            type: 'time',
            min: start_date,
            max: latest_timestamp,
            time: {
              unit: 'month'
            }
          },
          y: {
            beginAtZero: true
          }
        }
      },
    }

    if resource.budget_low_end.present?
      burnup_data[:data][:datasets].push({
        label: "Budget Low End",
        borderDash: [5, 5],
        backgroundColor: Stacks::Utils::COLORS[1], # color of dots
        borderColor: Stacks::Utils::COLORS[6], # color of line
        pointRadius: 0,
        data: [{
          x: start_date,
          y: resource.budget_low_end
        }, {
          x: latest_timestamp,
          y: resource.budget_low_end
        }]
      })
    end

    if resource.budget_high_end.present?
      burnup_data[:data][:datasets].push({
        label: "Budget High End",
        backgroundColor: Stacks::Utils::COLORS[14], # color of dots
        borderColor: Stacks::Utils::COLORS[4], # color of line
        pointRadius: 0,
        data: [{
          x: start_date,
          y: resource.budget_high_end
        }, {
          x: latest_timestamp,
          y: resource.budget_high_end
        }]
      })
    end

    burnup_data[:data][:datasets].push({
      backgroundColor: Stacks::Utils::COLORS[3], # color of dots
      borderColor: Stacks::Utils::COLORS[7], # color of line
      label: "Income",
      data: income_data[:income],
      pointRadius: 0
    })

    if resource.snapshot["spend"]
      burnup_data[:data][:datasets].push({
        backgroundColor: Stacks::Utils::COLORS[0], # color of dots
        borderColor: Stacks::Utils::COLORS[5], # color of line
        label: "Spend",
        data: resource.snapshot["spend"],
        pointRadius: 1
      })
    end

    if resource.snapshot["cost"]
      burnup_data[:data][:datasets].push({
        backgroundColor: Stacks::Utils::COLORS[2], # color of dots
        borderColor: Stacks::Utils::COLORS[8], # color of line
        label: "Cost",
        data: resource.snapshot["cost"],
        pointRadius: 1
      })
    end

    render(partial: 'show', locals: {
      burnup_data: burnup_data
    })

    # What Stacksbot has filed under this project's Notion projects: the flag
    # and win counts, the first flags, and the way into the log (app/admin/log.rb). Anyone who
    # can open this page can read the tracker, which is the log's own rule.
    # The module must never take this page down with it: when its rows cannot
    # be read (the sync's columns are missing, say) it says so in one line.
    log_summary =
      begin
        Stacks::ProjectLog.summary(resource)
      rescue StandardError => e
        Rails.logger.error("[project log] tracker #{resource.id} could not be read: #{e.class}: #{e.message}")
        nil
      end
    render(partial: "admin/log/module", locals: { tracker: resource, summary: log_summary })

    panel "Weekly Ships" do
      ships = resource.weekly_ships.includes(:document).order(sent_at: :desc).limit(20)
      if ships.any?
        # Asked once, not per row; readers who cannot open a ship's page get plain stars.
        can_open_ships = authorized?(:read, WeeklyShip)
        table_for ships do
          column("Sent") { |ws| "#{time_ago_in_words(ws.sent_at)} ago" }
          column("Subject") { |ws| ws.display_title }
          column("Sender") { |ws| ws.sender_label }
          # Coaching for the Project Lead from the nightly grader (Stacks::WeeklyShips::Grader).
          column("Grade") do |ws|
            if (g = ws.grade)
              if can_open_ships
                a(WeeklyShip.stars_label(g["stars"]), href: admin_weekly_ship_path(ws),
                  title: "#{g["stars"]} of 5. Open the coaching for this ship.",
                  style: "white-space: nowrap; text-decoration: none; font-size: inherit;")
              else
                span WeeklyShip.stars_label(g["stars"]), title: "#{g["stars"]} of 5", style: "white-space: nowrap;"
              end
            end
          end
          column("Feedback for the Project Lead") do |ws|
            if (g = ws.grade)
              div g["summary"]
              ul(style: "margin: 4px 0 0 16px;") { Array(g["suggestions"]).each { |s| li s } }
            end
          end
          column("") do |ws|
            url = ws.document.google_groups_permalink
            link_to("Open ↗", url, target: "_blank", rel: "noopener", style: "white-space: nowrap;") if url
          end
        end
        para "Grades are coaching for the Project Lead who sent the ship, scored overnight by a model. Never share them with the client.",
             style: "margin: 8px 12px; font-size: 13px;"
      else
        para em("No weekly ships linked yet.")
      end
    end
  end

  form do |f|
    f.inputs(class: "admin_inputs") do

      f.semantic_errors
      f.input :name
      f.input :budget_low_end
      f.input :budget_high_end
      f.input :monthly_budget_low_end, hint: "Retainers: the monthly budget the client tracks against. Enter one end for a fixed monthly budget (it mirrors to the other); clear both to remove it. Can coexist with the overall band above."
      f.input :monthly_budget_high_end

      if current_admin_user.is_admin?
        f.input :billing_model,
          as: :select,
          collection: Stacks::BillingModel.names.map { |n| [Stacks::BillingModel.for(n).label, n] },
          include_blank: false,
          hint: "Which payout split rules apply to this project's client work. new_deal_v2 is the 2026 rate card (33% treasury / 54% IC ceiling). Existing projects stay on new_deal_v1 until they wrap."
        f.input :target_profit_margin, hint: "The target profit margin for the project. This is used to calculate the project's profit margin."
        f.input :target_free_hours_percent, hint: "The target free hours percent for the project. This is used to calculate the project's free hours ratio."
      end

      f.input :notion_project_ids,
        as: :select,
        multiple: true,
        input_html: { multiple: true },
        label: "Notion Projects",
        collection: Stacks::Notion::Project.options_for(f.object),
        include_blank: false,
        hint: "This project's page or pages in the Notion Projects database. Stacksbot files what it sees about a project under them. Hold Cmd or Ctrl to choose more than one."

      f.has_many :project_tracker_links, heading: false, allow_destroy: true, new_record: 'Add a Project URL' do |a|
        a.input(:name, {
          label: "Link Name",
          prompt: "Add a name for this link",
        })
        a.input(:url, {
          label: "Link URL",
          prompt: "Add a name for this link",
          hint: "For a Twist channel, paste the channel's link, like #{ProjectTrackerLink.twist_channel_url(794756)}",
        })
        a.input(:link_type, {
          label: "Link Type",
          prompt: "Choose a type for this link",
        })
      end

      f.has_many :adhoc_invoice_trackers, heading: false, allow_destroy: true, new_record: 'Connect an Adhoc Invoice' do |a|
        a.input :qbo_invoice,
          as: :select,
          collection: QboInvoice.orphans
      end

      f.has_many :project_tracker_forecast_projects, heading: false, allow_destroy: true, new_record: 'Connect a Forecast Project' do |a|
        a.input(:forecast_project, {
          label: "Forecast Project",
          prompt: "Select a Forecast Project",
          collection: ForecastProject.candidates_for_association_with_project_tracker(resource),
          hint: "Is your project disabled? That's likely because it's Forecast Project Code is claimed by another Stacks Project Tracker. Choose a unique code for Forecast Projects associated with this Project Tracker. We sync with Forecast every ~10 minutes or so, so if you make changes there, check back here after 10 minutes."
        })
      end

      f.has_many :commissions, heading: "Commissions (paid back-of-house, deducted from each invoice line before contributor payouts)", allow_destroy: true, new_record: 'Add a Commission' do |c|
        c.input :type,
          as: :select,
          collection: [
            ["Percentage of line amount", "PercentageCommission"],
            ["Per billable hour", "PerHourCommission"],
          ],
          prompt: "Choose commission type"
        c.input :contributor,
          as: :select,
          collection: Contributor.includes(:forecast_person).map { |co| [co.display_name, co.id] },
          prompt: "Choose recipient (Contributor)"
        c.input :rate, hint: "For Percentage: 0.15 = 15%. For Per Hour: dollar amount per billable hour (e.g. 15.00)."
        c.input :notes, as: :text, input_html: { rows: 2 }
      end

      f.input :runn_project,
        as: :select,
        collection: RunnProject.candidates_for_association_with_project_tracker(resource),
        hint: "Runn.io Project missing? Check first it's not tentative or archived in Runn.io; and it should appear in this list after about 10 minutes."

      f.input :notes, label: "Notes (accepts markdown)"
    end

    f.actions
  end
end
