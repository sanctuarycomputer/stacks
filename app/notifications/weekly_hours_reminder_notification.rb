class WeeklyHoursReminderNotification < Noticed::Base
  deliver_by :database
  deliver_by :twist, class: "DeliveryMethods::Twist"
  param :missing_hours, :include_admins

  def topic
    "Weekly Hours Reminder (#{record.created_at.to_date.strftime("%B %d, %Y")})"
  end

  def body
    <<~HEREDOC
      👋 Hi #{(recipient.info || {}).dig("first_name")}!

      To help our team keep project budgets on track, we're asking everyone to please keep their hours **up to and including last friday**.

      **Currently, we're missing #{record.params[:missing_hours]} hours for you between the start of the month and last friday.** When you get a moment, please update your hours [here](https://forecastapp.com/864444/schedule/team) as per our hour tracking guidance [here](https://www.notion.so/garden3d/How-to-Record-your-Hours-ff971848f66d40cf818b930f05cfc533).

      **Tip:** If you consistently record last week's hours *before* the following Tuesday, you'll never see this reminder!

      🙏 Thank you!
    HEREDOC
  end
end
