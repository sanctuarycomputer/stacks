ActiveAdmin.register QualificationGrant do
  menu label: "Grants", parent: "Onboarding", priority: 5, if: proc { current_admin_user.is_admin? }
  actions :index, :new, :create
  permit_params :admin_user_id, :qualification_id, :note
  config.filters = false
  includes :admin_user, :qualification, :granted_by

  controller do
    include RefusesWritesWhileImpersonating

    # Granted by hand: stamped with the acting admin, never from the client,
    # never while impersonating (the concern), and never to oneself.
    def create
      # This override bypasses build_resource, which is where ActiveAdmin
      # normally authorizes a create. Without this line anyone signed in could
      # POST a grant.
      authorize! :create, QualificationGrant
      attrs = permitted_params[:qualification_grant] || {}
      if attrs[:admin_user_id].to_i == current_admin_user.id
        return redirect_to admin_qualification_grants_path, alert: "You can't grant yourself a qualification."
      end
      @qualification_grant = QualificationGrant.new(attrs.to_h.merge(granted_by: current_admin_user, granted_at: Time.current))
      if @qualification_grant.save
        redirect_to admin_qualification_grants_path, notice: "Granted."
      else
        render :new
      end
    end
  end

  index download_links: false do
    column :person do |g|
      g.admin_user.email
    end
    column :qualification
    column :granted_at
    column :granted_by do |g|
      g.granted_by&.email || "Earned"
    end
    column :note
  end

  form do |f|
    f.semantic_errors
    f.inputs do
      f.input :admin_user, as: :select, collection: AdminUser.order(:email).map { |u| [u.email, u.id] }
      f.input :qualification, as: :select, collection: Qualification.order(:name)
      f.input :note
    end
    f.actions
  end
end
