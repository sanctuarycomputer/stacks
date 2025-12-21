# class StaleTasksNotification < Noticed::Base
#   deliver_by :database
#   deliver_by :twist, class: "DeliveryMethods::Twist"
#   param :digest, :include_admins
#
#   def topic
#     "Stale Tasks Reminder (#{record.created_at.to_date.strftime("%B %d, %Y")})"
#   end
#
#   def body
#     stewardship_body = record.params[:digest][:tasks_stewarding].map(&:as_task).reduce("# Stewarding\n") do |acc, task|
#       acc + "- **[#{task.page_title}](#{task.notion_link})**: Due #{ApplicationController.helpers.time_ago_in_words(task.due_date)} ago\n"
#     end
#
#     assignment_body = record.params[:digest][:tasks_assigned].map(&:as_task).reduce("# Assigned\n") do |acc, task|
#       acc + "- **[#{task.page_title}](#{task.notion_link})**: Due #{ApplicationController.helpers.time_ago_in_words(task.due_date)} ago\n"
#     end
#
#     <<~HEREDOC
#       👋 Hi #{(recipient.info || {}).dig("first_name")}!
#
#       You're either a steward or assignee on the following Notion tasks that are now overdue. A company is an enormous tree of cascading due dates, and the best companies rarely miss the deadlines they commit to.
#
#       Can you please update the due date for the following to something super realistic? It's better to pad the due date than to miss it!
#
#       #{stewardship_body}
#       #{assignment_body}
#
#       Thank you!
#     HEREDOC
#   end
# end
