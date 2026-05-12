class Ledger < ApplicationRecord
  belongs_to :enterprise
  belongs_to :contributor

  validates :enterprise_id, uniqueness: { scope: :contributor_id }

  def self.find_or_create_for(enterprise:, contributor:)
    find_or_create_by!(enterprise: enterprise, contributor: contributor)
  end
end
