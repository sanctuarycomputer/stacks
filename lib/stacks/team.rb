class Stacks::Team
  class << self
    def twist
      @_twist ||= Stacks::Twist.new
    end

    def mean_tenure_in_days(admin_users_tenure_tuples = admin_users_sorted_by_tenure_in_days)
      tenures = admin_users_tenure_tuples.reject{|a| a[:considered_temporary] }.map{|tuple| tuple[:days]}
      tenures.sum(0.0) / tenures.size
    end

    def admin_users_sorted_by_tenure_in_days
      AdminUser.core.map do |a|
        {
          admin_user: a,
          days: a.full_time_periods.map{|ftp| ftp.period_ended_at - ftp.period_started_at}.reduce(:+).to_i,
          considered_temporary: a.considered_temporary?
        }
      end.sort {|a,b| b[:days] <=> a[:days]}
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
        admin_user = AdminUser.find_or_create_by_g3d_uid!(e)
      end

      twist_users = twist.get_workspace_users.parsed_response
      twist_users.select do |u|
        u["email"].ends_with?("@sanctuary.computer") || u["email"].ends_with?("@xxix.co")
      end.each do |u|
        AdminUser.find_or_create_by_g3d_uid!(u["email"])
      end

      ForecastPerson.all.select do |fp|
        (fp.email || "").ends_with?("@sanctuary.computer") || (fp.email || "").ends_with?("@xxix.co")
      end.each do |fp|
        admin_user = AdminUser.find_or_create_by_g3d_uid!(fp.email)
        # In the past, we'd seed the first Studio Membership from a forecast tag,
        # so this is for backward compatibility here. However, as garden3d has evolved, ppl
        # have moved between studios, and now the best place to administer the studio
        # an admin_user is currently a part of is by updating that on their AdminUser#Show
        # page in Active Admin.
        if admin_user.studio_memberships.empty?
          fp.studios.each do |s|
            StudioMembership.find_or_create_by!(
              studio: s,
              admin_user: admin_user,
              started_at: admin_user.created_at
            )
          end
        end
      end
    end
  end
end
