class DocumentContact < ApplicationRecord
  belongs_to :document
  belongs_to :contact, optional: true
end
