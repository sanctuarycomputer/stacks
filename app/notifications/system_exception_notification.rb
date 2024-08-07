class SystemExceptionNotification < Noticed::Base
  deliver_by :database
  deliver_by :twist, class: "DeliveryMethods::Twist"
  param :exception, :include_admins

  def topic
    "System Exception Occurred (#{record.created_at.to_date.strftime("%B %d, %Y")})"
  end

  def body
    <<~HEREDOC
      # Exception
      `#{params[:exception][:klass]}: #{params[:exception][:message]}`

      # Backtrace:
      ```
      #{(params[:exception][:backtrace] || []).first(5).join("\n")}
      ```
    HEREDOC
  end
end
