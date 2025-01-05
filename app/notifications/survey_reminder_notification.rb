class SurveyReminderNotification < Noticed::Base
  deliver_by :database
  deliver_by :twist, class: "DeliveryMethods::Twist"
  param :include_admins

  def topic
    "Survey Reminder (#{record.created_at.to_date.strftime("%B %d, %Y")})"
  end

  def body
    <<~HEREDOC
      👋 Hi #{(recipient.info || {}).dig("first_name")}!

      There's survey(s) in Stacks awaiting your response! Please try to carve at least ~15 minutes for each survey, your responses will inform how we evolve our business.

      📝 Head over [here](https://stacks.garden3d.net/admin/surveys) to fill it out.

      🙏 Thank you!
    HEREDOC
  end
end
