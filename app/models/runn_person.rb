# Nightly mirror of Runn people (Stacks::Runn#sync_people!). Never pruned;
# Runn's isArchived is mirrored instead.
class RunnPerson < ApplicationRecord
  self.primary_key = "runn_id"
  has_many :runn_assignments, foreign_key: :person_id, primary_key: :runn_id

  scope :active, -> { where(is_archived: false) }

  # Ad-hoc lookup. The projection engine builds one email index instead of
  # calling this per row.
  def contributor
    return @contributor if defined?(@contributor)
    e = email.to_s.strip.downcase
    @contributor = e.present? ? Contributor.joins(:forecast_person).find_by("lower(forecast_people.email) = ?", e) : nil
  end
end
