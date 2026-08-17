# Wraps a NotionPage row from the "🤼 Human Operating Manuals" database.
# Synced daily by the DATABASE_IDS sweep in lib/tasks/stacks.rake; consumed
# by Stacks::TaskBuilder::Discoveries::HumanOperatingManuals to nag active
# admins who are missing a manual or its Superpowers PDF.
class Stacks::Notion::HumanOperatingManual < Stacks::Notion::Base
  class << self
    def all
      NotionPage.human_operating_manual.map(&:as_human_operating_manual)
    end
  end

  # Downcased "Email" property — the join key to AdminUser.email. Nil when unset.
  def email
    value = get_prop_value("Email")
    value.is_a?(String) ? value.downcase : nil
  end

  # True when the "Pigment.is Superpowers PDF" file property holds ≥1 file.
  def superpowers_pdf?
    files = get_prop_value("Pigment.is Superpowers PDF")
    files.is_a?(Array) && files.any?
  end
end
