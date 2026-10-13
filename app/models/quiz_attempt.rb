# correct_count / question_count / passed are fixed at submission and never
# recomputed; answers is a record only.
class QuizAttempt < ApplicationRecord
  include BustsTaskCache

  belongs_to :admin_user
  belongs_to :learning_module

  validates :correct_count, :question_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
