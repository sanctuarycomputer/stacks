class ModuleCompletion < ApplicationRecord
  include BustsTaskCache

  belongs_to :admin_user
  belongs_to :learning_module

  validates :completed_at, presence: true
  validates :learning_module_id, uniqueness: { scope: :admin_user_id }
end
