class Stacks::Twist
  include HTTParty
  base_uri 'api.twist.com/api/v3'

  def initialize()
    @headers = {
      "Authorization": "Bearer #{Stacks::Utils.config[:twist][:token]}",
    }
  end

  def get_default_workspace
    self.class.get("/workspaces/get_default", headers: @headers)
  end

  def get_channel(channel_id)
    self.class.get("/channels/getone", {
      headers: @headers,
      query: {
        id: channel_id
      }
    })
  end

  def get_all_threads(channel_id)
    self.class.get("/threads/get", {
      headers: @headers,
      query: {
        channel_id: channel_id
      }
    })
  end

  def add_thread(channel_id, thread_title, thread_content)
    self.class.post("/threads/add", {
      headers: @headers,
      body: {
        channel_id: channel_id,
        title: thread_title,
        content: thread_content,
      }
    })
  end

  def add_comment_to_thread(thread_id, thread_content)
    self.class.post("/comments/add", {
      headers: @headers,
      body: {
        thread_id: thread_id,
        content: thread_content
      }
    })
  end

  def get_workspace_users
    self.class.get("/workspaces/get_users?id=#{Stacks::Utils.config[:twist][:workspace_id]}", headers: @headers)
  end

  def get_conversation(conversation_id)
    self.class.post("/conversations/getone", {
      headers: @headers,
      query: {
        id: conversation_id
      }
    })
  end

  def get_or_create_conversation(user_ids_as_comma_seperated_string)
    self.class.post("/conversations/get_or_create", {
      headers: @headers,
      body: {
        workspace_id: Stacks::Utils.config[:twist][:workspace_id],
        user_ids: "[#{user_ids_as_comma_seperated_string}]"
      }
    })
  end

  def add_message_to_conversation(conversation_id, content)
    self.class.post("/conversation_messages/add", {
      headers: @headers,
      body: {
        conversation_id: conversation_id,
        content: content,
      }
    })
  end
end
