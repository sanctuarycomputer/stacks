class GroupThread < ApplicationRecord
  has_many :documents, as: :source_record, dependent: :nullify
end
