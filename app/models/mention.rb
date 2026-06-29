class Mention < ApplicationRecord
  belongs_to :chunk
  belongs_to :contact, optional: true

  enum status: { unresolved: 0, resolved: 1, ambiguous: 2 }
end
