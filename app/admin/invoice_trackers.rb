ActiveAdmin.register InvoiceTracker do
  menu label: "Invoices"
  config.filters = false
  config.paginate = false
  actions :index, :show, :edit, :update
  belongs_to :invoice_pass
  permit_params :notes, :allow_early_contributor_payouts_on, :company_treasury_split, :qbo_invoice_id

  action_item :attempt_generate, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to(
      "Regenerate",
      attempt_generate_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
      method: :post
    )
  end

  action_item :notify_reviewers, only: :show, if: proc {
    current_admin_user.is_admin? || resource.admin_user == current_admin_user
  } do
    if resource.sent?
      link_to(
        "Notify Reviewers",
        "#",
        onclick: "alert('This invoice has already been sent. Reviewers will not be notified.'); return false;"
      )
    else
      last_label =
        if resource.reviewers_last_notified_at
          " (last: #{time_ago_in_words(resource.reviewers_last_notified_at)} ago)"
        else
          ""
        end
      link_to(
        "Notify Reviewers#{last_label}",
        notify_reviewers_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        method: :post,
        data: { confirm: "Send a 24-hour review reminder to all Account Leads and Project Leads on the connected Project Trackers?" }
      )
    end
  end

  member_action :toggle_contributor_payout_acceptance, method: :post do
    cp = ContributorPayout.find(params[:contributor_payout_id])
    return unless cp.contributor.forecast_person.try(:admin_user) == current_admin_user || current_admin_user.is_admin?
    cp.toggle_acceptance!
    return redirect_to(
      admin_invoice_pass_invoice_tracker_path(params[:invoice_pass_id], params[:id], format: :html),
      notice: "Success",
    )
  end

  member_action :toggle_ownership, method: :post do
    if resource.admin_user.present? && resource.admin_user == current_admin_user
      resource.update!(admin_user: nil)
      return redirect_to(
        admin_invoice_pass_invoice_trackers_path(resource.invoice_pass, resource, format: :html),
        notice: "Unclaimed invoice.",
      )
    else
      resource.update!(admin_user: current_admin_user)
      return redirect_to(
        admin_invoice_pass_invoice_trackers_path(resource.invoice_pass, resource, format: :html),
        notice: "Claimed!",
      )
    end
  end

  member_action :notify_reviewers, method: :post do
    unless current_admin_user.is_admin? || resource.admin_user == current_admin_user
      return redirect_back(
        fallback_location: admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        alert: "Not authorized to notify reviewers."
      )
    end

    if resource.qbo_invoice.nil?
      return redirect_back(
        fallback_location: admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        alert: "Can't notify reviewers — this invoice hasn't been generated yet."
      )
    end

    if resource.sent?
      return redirect_back(
        fallback_location: admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        alert: "This invoice has already been sent. Reviewers will NOT be notified."
      )
    end

    month = resource.invoice_pass.start_of_month
    host = "https://stacks.garden3d.net"
    invoice_link = Rails.application.routes.url_helpers.admin_invoice_pass_invoice_tracker_url(
      resource.invoice_pass, resource, host: host
    )

    twist = Stacks::Twist.new
    twist_users_by_email =
      twist.get_workspace_users.parsed_response.index_by { |u| u["email"] }
    admin_twist_users =
      AdminUser.admin.map { |a| twist_users_by_email[a.email] }.compact

    sent = []
    skipped = []

    resource.project_trackers.each do |pt|
      al = pt.account_lead_for_month(month)
      pl = pt.project_lead_for_month(month)

      if al.nil? && pl.nil?
        skipped << "#{pt.name} (no Account Lead or Project Lead set)"
        next
      end

      al_twist = al && twist_users_by_email[al.email]
      pl_twist = pl && twist_users_by_email[pl.email]

      # Primary is the AL when present; otherwise fall back to PL.
      primary_twist = al_twist || pl_twist
      if primary_twist.nil?
        skipped << "#{pt.name} (reviewers not on Twist: #{[al&.email, pl&.email].compact.join(", ")})"
        next
      end

      participant_ids = ([primary_twist, pl_twist, al_twist, *admin_twist_users]
        .compact
        .uniq { |u| u["id"] }
        .map { |u| u["id"] })
        .join(",")

      mention = "[#{primary_twist["name"]}](twist-mention://#{primary_twist["id"]})"
      pt_url = Rails.application.routes.url_helpers.admin_project_tracker_url(pt, host: host)

      body = <<~HEREDOC
        💸 Hi #{mention}!

        The [invoice](#{invoice_link}) for **#{pt.name}** (#{month.strftime("%B %Y")}) is ready for your review. We will send this invoice in 24 hours. If anything looks off, please flag it now.

        **→ If you miss this window, it will be sent without your approval and can no longer be modified.**

        ☝️ All Contributor Payouts will be derived from this invoice, so it's important to get this right *before* it's sent.

        Thanks!
      HEREDOC

      conversation = twist.get_or_create_conversation(participant_ids)
      twist.add_message_to_conversation(conversation["id"], body)
      sent << "#{pt.name} → @#{primary_twist["name"]}"
      sleep(0.1) # be kind to the Twist API
    end

    resource.update!(reviewers_last_notified_at: Time.current) if sent.any?

    flash_msg = []
    flash_msg << "Sent #{sent.length}: #{sent.join("; ")}" if sent.any?
    flash_msg << "Skipped: #{skipped.join("; ")}" if skipped.any?

    redirect_back(
      fallback_location: admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
      notice: flash_msg.join(" — ").presence || "Nothing to send."
    )
  end

  member_action :attempt_generate, method: :post do
    if resource.qbo_invoice_id.present?
      return redirect_to(
        admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        alert: "Can not attempt to generate an invoice when a QBO Invoice ID is already set. (Delete the invoice in QBO if you'd like to regenerate.)"
      )
    end

    if resource.configuration_errors.any?
      return redirect_to(
        admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        alert: "Can not attempt to generate an invoice Configuration Errors are present."
      )
    end

    result = resource.make_invoice!
    if result.is_a?(Quickbooks::Model::Invoice)
      return redirect_to(
        admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        notice: "Invoice regenerated."
      )
    else
      return redirect_to(
        admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
        alert: "Could not regenerate invoice."
      )
    end
  end

  index download_links: false, :title => proc { "Invoices for #{self.parent.invoice_month}" } do
    column :client do |resource|
      resource.forecast_client.name
    end
    column :value do |resource|
      number_to_currency(resource.value)
    end
    column :surplus do |resource|
      number_to_currency(resource.surplus)
    end
    column :stale? do |resource|
      stale = resource.changes_in_forecast.any?
      span(stale ? "Stale" : "In sync", class: "pill #{stale ? "changed" : "unchanged"}")
    end
    column :invoicing_status do |resource|
      span(resource.status.to_s.humanize, class: "pill #{resource.status}")
    end
    column :payout_status do |resource|
      span(resource.contributor_payouts_status.to_s.humanize, class: "pill #{resource.contributor_payouts_status}")
    end
    column "Reviewers Notified" do |resource|
      if resource.reviewers_last_notified_at
        "#{time_ago_in_words(resource.reviewers_last_notified_at)} ago"
      else
        span("Not yet", class: "pill error")
      end
    end
    column :owner do |resource|
      if resource.admin_user.present?
        resource.admin_user
      else
      span("Unclaimed", class: "pill error")
      end
    end
    actions do |resource|
      links = []

      if resource.admin_user.nil?
        links << link_to(
          "Claim ↗",
          toggle_ownership_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
          method: :post
        )
      elsif resource.admin_user == current_admin_user
        links << link_to(
          "Unclaim ↗",
          toggle_ownership_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
          method: :post
        )
      end

      if current_admin_user.is_admin? || resource.admin_user == current_admin_user
        label = resource.reviewers_last_notified_at ? "Re-Notify ↗" : "Notify ↗"
        links << if resource.sent?
          link_to(
            label,
            "#",
            onclick: "alert('This invoice has already been sent. Reviewers will not be notified.'); return false;"
          )
        else
          link_to(
            label,
            notify_reviewers_admin_invoice_pass_invoice_tracker_path(resource.invoice_pass, resource),
            method: :post,
            data: { confirm: "Send a 24-hour review reminder to all Account Leads and Project Leads on the connected Project Trackers?" }
          )
        end
      end

      safe_join(links, " ")
    end
  end

  controller do
    def show
      unless resource.qbo_invoice.try(:sync!)
        resource.reload
      end
      super
    end

    def update
      if params[:invoice_tracker][:allow_early_contributor_payouts_on].present?
        raise "Only admins can schedule early contributor payouts" unless current_admin_user.is_admin?
      end
      super
    end
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :forecast_client, input_html: { disabled: true }
      f.input :qbo_invoice,
        as: :select,
        collection: QboInvoice.orphans,
        input_html: { disabled: !current_admin_user.is_admin? }
      if current_admin_user.is_admin?
        f.input :company_treasury_split, as: :number, input_html: { step: 0.01 }
      end
      f.input :allow_early_contributor_payouts_on, as: :date_picker
      f.input :notes, label: "❗Important Notes (accepts markdown)"
    end
    f.actions
  end

  show do
    if invoice_tracker.status == :not_made
      render 'not_made', { invoice_tracker: invoice_tracker }
    else
      render 'invoice_tracker', { invoice_tracker: invoice_tracker }
    end
  end
end
