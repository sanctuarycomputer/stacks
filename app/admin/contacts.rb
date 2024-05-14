ActiveAdmin.register Contact do
  config.filters = false
  actions :index, :new, :create, :edit, :update
  permit_params :email, sources: []

  collection_action :import_contacts, method: :post do
    csv = CSV.parse(File.read(params["file"]), :headers => true)
    data = csv.map(&:to_hash).each do |row|
      d = {
        email: row["Email"] || row["email"] || row["Email Address"],
        sources: row["Sources"] || row["sources"] || row["Source"] || row["source"]
      }
      contact = Contact.create_or_find_by!(email: d[:email])
      contact.update(sources: [*contact.sources, *(d[:sources].split(" ").map(&:strip) || [])].uniq)
    end
    redirect_to admin_contacts_path, notice: "#{data.length} Contacts processed!"
  end

  controller do
    def update
      params["contact"]["sources"] = params["contact"]["sources"].split(" ")
      super
    end
  end

  index download_links: false do
    column :email
    column :sources
    actions
  end
end
