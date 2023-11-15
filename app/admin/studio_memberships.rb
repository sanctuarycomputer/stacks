ActiveAdmin.register StudioMembership do
  belongs_to :admin_user
  permit_params :admin_user_id, :studio_id
end
