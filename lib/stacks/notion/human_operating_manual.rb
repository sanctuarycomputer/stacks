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

  # Downcased candidate emails for the manual's owner: the "Email" property
  # plus every person in the "Who" people property. Real manuals frequently
  # have only one or the other filled in.
  def emails
    out = []
    email_prop = get_prop_value("Email")
    out << email_prop if email_prop.is_a?(String)
    who = get_prop_value("Who")
    people = who.is_a?(Array) ? who : []
    out.concat(people.map { |p| p.dig("person", "email") }.compact)
    out.map(&:downcase).uniq
  end

  # First resolvable email — used as the display fallback.
  def email
    emails.first
  end

  # True when the "Pigment.is Superpowers PDF" file property holds ≥1 file.
  def superpowers_pdf?
    files = get_prop_value("Pigment.is Superpowers PDF")
    files.is_a?(Array) && files.any?
  end
end
