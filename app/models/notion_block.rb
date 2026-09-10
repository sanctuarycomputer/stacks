# One row per Notion block, raw object in `data`. Children of X are
# where(parent_id: X).order(:position). page_id is the root page, for invalidation.
class NotionBlock < ApplicationRecord
  scope :children_of, ->(parent_id) { where(parent_id: parent_id).order(:position) }
end
