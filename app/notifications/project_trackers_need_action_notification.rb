class ProjectTrackersNeedActionNotification < Noticed::Base
  deliver_by :database
  deliver_by :twist, class: "DeliveryMethods::Twist"
  param :digest, :include_admins

  def topic
    "Project Trackers needing Action (#{record.created_at.to_date.strftime("%B %d, %Y")})"
  end

  def body
    parent_body = <<~HEREDOC
      👋 Hi #{(recipient.info || {}).dig("first_name")}!

      You're the PL on the following projects that need some attention. Can you please address these issues ASAP?

    HEREDOC

    likely_complete = record.params[:digest][:likely_complete]
    if likely_complete.any?
      likely_complete_intro_body = <<~HEREDOC
        # Likely Complete

        The following Project Trackers haven't had a recorded hour in 1 month and their Project Tracker name in Stacks does not include the ✨ magic words ✨ `ongoing` or `retainer`.

        **You can mark this project complete by clicking the "Mark as Work Complete" button on the Project Tracker page.**

      HEREDOC
      likely_complete_body = likely_complete.reduce(likely_complete_intro_body) do |acc, pt|
        link = Rails.application.routes.url_helpers.admin_project_tracker_url(pt.id, host: "https://stacks.garden3d.net")
        acc + "- [#{pt.name} ↗](#{link})\n"
      end

      parent_body = <<~HEREDOC
        #{parent_body}
        #{likely_complete_body}
      HEREDOC
    end

    capsule_pending = record.params[:digest][:capsule_pending]
    if capsule_pending.any?
      capsule_pending_intro_body = <<~HEREDOC
        # Capsule Pending

        The following Project Trackers have been marked as complete, but the project capsule has not yet been completed. A healthy garden3d aspires to have project capsules done within 4 - 6 weeks.

        **You can learn how to run a project capsule [here](https://www.notion.so/garden3d/Creating-a-Project-Capsule-Profitability-Study-c5a17dbb8be74edc8960a61b2484aa0e).**

      HEREDOC
      capsule_pending_body = capsule_pending.reduce(capsule_pending_intro_body) do |acc, pt|
        link = Rails.application.routes.url_helpers.admin_project_tracker_url(pt.id, host: "https://stacks.garden3d.net")
        acc + "- [#{pt.name} ↗](#{link})\n"
      end

      parent_body = <<~HEREDOC
        #{parent_body}
        #{capsule_pending_body}
      HEREDOC
    end

    awaiting_sign_off = (record.params[:digest][:awaiting_sign_off] || [])
    if awaiting_sign_off.any?
      awaiting_sign_off_intro_body = <<~HEREDOC
        # Awaiting Admin Sign-Off

        You've finished the following Project Capsules, but they opt out of one or more close-out steps, so an admin needs to approve them before they're marked complete. Nothing is required from you — though if you'd rather not wait, doing the step for real clears it immediately.

      HEREDOC
      awaiting_sign_off_body = awaiting_sign_off.reduce(awaiting_sign_off_intro_body) do |acc, pt|
        link = Rails.application.routes.url_helpers.admin_project_tracker_url(pt.id, host: "https://stacks.garden3d.net")
        acc + "- [#{pt.name} ↗](#{link})\n"
      end

      parent_body = <<~HEREDOC
        #{parent_body}
        #{awaiting_sign_off_body}
      HEREDOC
    end

    <<~HEREDOC
      #{parent_body}

      Thank you!
    HEREDOC
  end
end
