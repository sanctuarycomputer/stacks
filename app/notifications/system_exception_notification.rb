class SystemExceptionNotification < Noticed::Base
  deliver_by :database
  param :exception

  def topic
    "System Exception Occurred (#{record.created_at.to_date.strftime("%B %d, %Y")})"
  end

  def body
    exc = params[:exception].with_indifferent_access
    <<~HEREDOC
      # Exception
      `#{exc[:klass]}: #{exc[:message]}`

      # Backtrace:
      ```
      #{(exc[:backtrace] || []).reject { |l| l.include?("/app/vendor/") }.join("\n")}
      ```
    HEREDOC
  end
end
