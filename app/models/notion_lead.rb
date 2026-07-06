# Derived projection of NotionPage lead rows (dates parsed once at sync time
# by Leads::SyncFromNotionPages) so lead datapoints are computable in SQL.
class NotionLead < ApplicationRecord
  belongs_to :notion_page
  has_many :notion_lead_studios, dependent: :delete_all
  has_many :studios, through: :notion_lead_studios

  # garden3d sees every lead (mirrors Studio#new_biz_leads).
  scope :for_studio, ->(studio) {
    if studio.is_garden3d?
      all
    else
      joins(:notion_lead_studios).where(notion_lead_studios: { studio_id: studio.id })
    end
  }
end
