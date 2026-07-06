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

      There's survey(s) in Stacks awaiting your response!

      📝 Head over [here](https://stacks.garden3d.net/admin/all_surveys) to fill it out.

      🙏 Thank you!
    HEREDOC
  end
end
