class Contact < ApplicationRecord
  validates :email, format: { with: Devise.email_regexp }

  def dedupe!
    dupes = Contact.where("LOWER(email) LIKE ?", "%#{email.downcase}%")
    return unless dupes.length > 1

    new_record =
      dupes.reduce(Contact.new) do |new_record, dupe|
        new_record.email = dupe.email.downcase
        new_record.sources = [*new_record.sources, *dupe.sources]
        new_record.apollo_id = dupe.apollo_id if dupe.apollo_id.present?
        new_record
      end

    ActiveRecord::Base.transaction do
      dupes.delete_all
      new_record.save!
    end
  end
end
