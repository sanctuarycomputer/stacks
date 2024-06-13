ActiveAdmin.register Contact do
  config.filters = true
  config.per_page = [1000, 500, 100]
  actions :index, :show, :new, :create, :edit, :update
  permit_params :email, sources: []
  config.sort_order = "updated_at_desc"

  filter :email_cont, as: :string, label: "Email Contains"
  filter :address_cont, as: :string, label: "Address Contains"

  scope :all, default: true
  scope :synced_to_apollo
  scope :not_synced_to_apollo

  collection_action :import_contacts, method: :post do
    csv = CSV.parse(File.read(params["file"]), :headers => true)
    data = csv.map(&:to_hash).each do |row|
      d = {
        email: row["Email"] || row["email"] || row["Email Address"],
        sources: row["Sources"] || row["sources"] || row["Source"] || row["source"]
      }
      if d[:email].present?
        contact = Contact.create_or_find_by!(email: d[:email])
        contact.update(sources: [*contact.sources, *(d[:sources].split(" ").map(&:strip) || [])].uniq)
      end
    end
    redirect_to admin_contacts_path, notice: "#{data.length} Contacts processed!"
  end

  controller do
    def update
      params["contact"]["sources"] = params["contact"]["sources"].split(" ")
      super
    end
  end

  member_action :sync_to_apollo, method: :post do
    deduped = resource.dedupe!
    deduped.sync_to_apollo!
    redirect_to admin_contact_path(deduped), notice: "Success!"
  end

  action_item :sync_to_apollo, only: :show do
    link_to "Sync to Apollo", sync_to_apollo_admin_contact_path(resource), method: :post
  end

  index download_links: [:csv] do
    column :email
    column :sources
    column :last_sync do |contact|
      "#{ApplicationController.helpers.time_ago_in_words(contact.updated_at)} ago"
    end
    column :company do |contact|
      org_name = contact.apollo_data.dig("organization", "name") || contact.apollo_data.dig("organization_name") || "—"
      org_linkedin = contact.apollo_data.dig("organization", "linkedin_url")
      org_website = contact.apollo_data.dig("organization", "website_url")
      org_apollo_id = contact.apollo_data.dig("organization_id")
      org_link = org_linkedin || org_website || (org_apollo_id && "https://app.apollo.io/#/organizations/#{org_apollo_id}")

      if org_link
        a(org_name, href: org_link, target: "_blank")
      else
        org_name
      end
    end
    column :address do |contact|
      contact.apollo_data.dig("present_raw_address") || "—"
    end
    column :apollo do |contact|
      if contact.apollo_id.present?
        a("Open↗", href: contact.apollo_link, target: "_blank")
      else
        link_to "Sync!", sync_to_apollo_admin_contact_path(contact), method: :post
      end
    end
    actions
  end
end
