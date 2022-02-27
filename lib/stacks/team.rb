class Stacks::Team
  class << self
    def twist
      @_twist ||= Stacks::Twist.new
    end

    def discover!
      twist_users = twist.get_workspace_users.parsed_response
      twist_users.select do |u|
        u["email"].ends_with?("@sanctuary.computer") || u["email"].ends_with?("@xxix.co")
      end.each do |u|
        AdminUser.find_or_create_by!(
          email: u["email"],
          provider: "google_oauth2"
        )
      end

      ForecastPerson.all do |p|
        AdminUser.find_or_create_by!(
          email: p.email,
          provider: "google_oauth2"
        )
      end
    end
  end
end
