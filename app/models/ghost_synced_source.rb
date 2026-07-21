# A row's existence means "contacts with this source are pushed to Ghost".
class GhostSyncedSource < ApplicationRecord
  validates :source, presence: true, uniqueness: true
end
