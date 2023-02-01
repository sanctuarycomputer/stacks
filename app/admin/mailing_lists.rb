ActiveAdmin.register MailingList do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :create, :edit, :update, :destroy
  permit_params :name
  menu false
  belongs_to :studio

  index download_links: false do
    column :name
    column :provider
    actions
  end

  member_action :import_mailing_list, method: :post do
    csv = CSV.parse(File.read(params["file"]), :headers => true)
    data = csv.map(&:to_hash).map do |row|
      {
        mailing_list_id: params["id"],
        email: row["Email"] || row["email"] || row["Email Address"],
        info: row.except("email", "Email Address")
      }
    end

    ActiveRecord::Base.transaction do
      MailingListSubscriber.where(mailing_list_id: resource.id).delete_all
      MailingListSubscriber.upsert_all(data, unique_by: [:mailing_list_id, :email])
      resource.update!(snapshot: resource.snapshot.merge({ Date.today.iso8601 => resource.mailing_list_subscribers.count }))
    end

    redirect_to admin_studio_mailing_list_path, notice: "Mailing List Updated!"
  end

  show do
    render(partial: "show", locals: {
    })
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :name
      f.input :provider
    end

    f.actions
  end
end
