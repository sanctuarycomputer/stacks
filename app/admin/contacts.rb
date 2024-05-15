ActiveAdmin.register Contact do
  config.filters = true
  config.per_page = [1000, 500, 100]
  actions :index, :new, :create, :edit, :update
  permit_params :email, sources: []
  config.sort_order = "updated_at_desc"

  filter :email_cont, as: :string, label: "Email Contains"

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

  index download_links: [:csv] do
    column :email
    column :sources
    actions
  end
end
