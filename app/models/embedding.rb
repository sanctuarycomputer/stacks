class Embedding < ApplicationRecord
  belongs_to :owner, polymorphic: true
  has_neighbors :embedding
end
