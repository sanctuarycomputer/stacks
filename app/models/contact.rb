class Contact < ApplicationRecord
  validates :email, format: { with: Devise.email_regexp }

  scope :synced_to_apollo, -> {
    where.not(apollo_id: nil)
  }
  scope :not_synced_to_apollo, -> {
    where(apollo_id: nil)
  }

  scope :address_cont, ->(value) { where_address_contains(value) }

  def self.ransackable_scopes(*)
    %i(address_cont)
  end

  def self.where_address_contains(value)
    self.where("apollo_data ->> 'present_raw_address' LIKE :value", value: "%#{value}%") 
  end

  def apollo_link
    "https://app.apollo.io/#/contacts/#{apollo_id}"
  end

  def sync_to_apollo!(apollo = Stacks::Apollo.new)
    existing_contacts = apollo.search_by_email(self.email)
    apollo_contact = existing_contacts.first || apollo.create_contact(self.email)
    self.update(apollo_id: apollo_contact["id"], apollo_data: apollo_contact)
  end

  def dedupe!
    self.update(sources: self.sources.uniq)

    dupes = Contact.where("LOWER(email) LIKE ?", "%#{email.downcase}%")
    return self unless dupes.length > 1

    new_record =
      dupes.reduce(Contact.new) do |new_record, dupe|
        new_record.email = dupe.email.downcase
        new_record.sources = [*new_record.sources, *dupe.sources].uniq
        new_record.apollo_id = dupe.apollo_id if dupe.apollo_id.present?
        new_record
      end

    ActiveRecord::Base.transaction do
      dupes.delete_all
      new_record.save!
    end

    new_record
  end
end
