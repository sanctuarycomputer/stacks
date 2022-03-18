class Stacks::Team
  class << self
    def twist
      @_twist ||= Stacks::Twist.new
    end

    def discover!
      AdminUser.all.each do |admin_user|
        unless (admin_user.email || "").ends_with?("@sanctuary.computer") || (admin_user.email || "").ends_with?("@xxix.co")
          admin_user.destroy!
        end
      end

      twist_users = twist.get_workspace_users.parsed_response
      twist_users.select do |u|
        u["email"].ends_with?("@sanctuary.computer") || u["email"].ends_with?("@xxix.co")
      end.each do |u|
        AdminUser.find_or_create_by!(
          email: u["email"],
          provider: "google_oauth2"
        )
      end

      ForecastPerson.all.select do |fp|
        (fp.email || "").ends_with?("@sanctuary.computer") || (fp.email || "").ends_with?("@xxix.co")
      end.each do |fp|
        admin_user = AdminUser.find_or_create_by!(
          email: fp.email,
          provider: "google_oauth2"
        )
        fp.studios.each do |s|
          StudioMembership.find_or_create_by!(
            studio: s,
            admin_user: admin_user
          )
        end
      end
    end
  end
end
