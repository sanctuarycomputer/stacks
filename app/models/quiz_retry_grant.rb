# One row = one extra quiz attempt an admin allowed a person on a module.
class QuizRetryGrant < ApplicationRecord
  include BustsTaskCache

  belongs_to :admin_user
  belongs_to :learning_module
  belongs_to :granted_by, class_name: "AdminUser", optional: true
end
