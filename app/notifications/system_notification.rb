class SystemNotification < Noticed::Base
  deliver_by :database

  def topic
    "topic"
  end

  def body
    <<~HEREDOC
    body
    HEREDOC
  end
end
