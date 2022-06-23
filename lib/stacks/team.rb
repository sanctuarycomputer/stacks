class Stacks::Team
  class << self
    def twist
      @_twist ||= Stacks::Twist.new
    end

    def fetch_from_google_workspace(domain)
      service = Google::Apis::AdminDirectoryV1::DirectoryService.new
      service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
        scope: Google::Apis::AdminDirectoryV1::AUTH_ADMIN_DIRECTORY_USER_READONLY
      )
      service.authorization.sub = "hugh@sanctuary.computer"
      service.authorization.fetch_access_token!

      next_page_token = nil
      all = []
      begin
        response = service.list_users(domain: domain)
        all = [*all, *response.users]
        next_page_token = response.next_page_token
      rescue => e
        raise e
      end while (response.next_page_token.present?)
      return all
    end

    def discover!
      AdminUser.all.each do |admin_user|
        unless (admin_user.email || "").ends_with?("@sanctuary.computer") || (admin_user.email || "").ends_with?("@xxix.co")
          admin_user.destroy!
        end
      end

      sanctu_google_users = Stacks::Team
        .fetch_from_google_workspace("sanctuary.computer")
        .map{|u| u.emails.find{|e| e["primary"]}.dig("address")}

      xxix_google_users = Stacks::Team
        .fetch_from_google_workspace("xxix.co")
        .map{|u| u.emails.find{|e| e["primary"]}.dig("address")}

      [*sanctu_google_users, *xxix_google_users].each do |e|
        AdminUser.find_or_create_by!(
          email: e,
          provider: "google_oauth2"
        )
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
