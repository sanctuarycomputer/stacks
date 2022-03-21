class DeliveryMethods::Twist < Noticed::DeliveryMethods::Base
  def deliver
    @_twist ||= Stacks::Twist.new

    twist_users = @_twist.get_workspace_users.parsed_response
    admin_twist_users = (AdminUser.admin.map do |a|
      twist_users.find{ |tu| tu["email"] == a.email }
    end).compact

    recipient_twist_user =
      twist_users.find{|tu| tu["email"] == recipient.email}

    if recipient_twist_user.present?
      participant_ids = [*admin_twist_users, recipient_twist_user].map do |tu|
        tu["id"]
      end.compact
      conversation = @_twist.get_or_create_conversation(participant_ids)
      @_twist.add_message_to_conversation(conversation["id"], notification.body)
    end
  end
end
