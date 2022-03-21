class MissingHoursNotification < Noticed::Base
  deliver_by :database
  deliver_by :twist, class: "DeliveryMethods::Twist"
  param :missing_allocation

  def link
    "https://forecastapp.com/864444/schedule/team"
  end

  def topic
    "Missing Hours for #{record.created_at.to_date.strftime("%B, %Y")}"
  end

  def body
    <<~HEREDOC
      👋 Hi #{(recipient.info || {}).dig("first_name")}!

      👉 We'd like to send invoices today, but we can't do that until you've accounted for at least 8 hours of time for every business day last month.

      **We're missing at least `#{((params[:missing_allocation] || 0).to_f)} hrs` of your time last month. Please ensure you've accounted for at least 8 hours of time each day between #{(record.created_at.to_date - 1.month).beginning_of_month.to_formatted_s(:long)} and #{(record.created_at.to_date - 1.month).end_of_month.to_formatted_s(:long)}, then ping me back, so we can send out invoices and get us all paid!**

      - [Please fill them out when you get a chance.](https://forecastapp.com/864444/schedule/team) (And remember that [Time Off](https://help.getharvest.com/forecast/schedule/plan/scheduling-time-off/) or Internal Work also needs to be recorded!)

      - If you worked a long day, then a short day, or something like that, that's totally fine! Just mark the remaining hours of your short day as "Time Off".

      - If you're not sure how to do it, you can [learn about recording hours here](https://www.notion.so/garden3d/How-to-Record-your-Hours-ff971848f66d40cf818b930f05cfc533), or get in touch with your project lead. We're aiming for everyone to do this autonomously!

      - If you think something here is incorrect, please let me know!

      🙏 Thank you!
    HEREDOC
  end
end
