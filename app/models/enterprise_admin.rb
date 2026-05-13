class EnterpriseAdmin < ApplicationRecord
  belongs_to :enterprise
  belongs_to :admin_user

  validates :admin_user_id, uniqueness: { scope: :enterprise_id }
end
