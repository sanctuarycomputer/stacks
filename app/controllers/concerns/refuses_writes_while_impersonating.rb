# Authoring screens (course content, qualifications, grants) are the admin's own
# work. An admin who is impersonating anyone, even another admin, must not write
# them under that person's identity.
module RefusesWritesWhileImpersonating
  extend ActiveSupport::Concern

  included do
    before_action :refuse_write_while_impersonating!, only: [:new, :create, :edit, :update, :destroy]
  end

  private

  def refuse_write_while_impersonating!
    return unless impersonating?
    target = respond_to?(:collection_path, true) ? collection_path : admin_root_path
    redirect_to target, alert: "Stop impersonating first."
  end
end
