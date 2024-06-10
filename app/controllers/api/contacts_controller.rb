class Api::ContactsController < ApiController
  skip_before_action :verify_authenticity_token

  def create
    check_private_api_key!
    contact = Contact.create_or_find_by!(email: params["email"].downcase)
    contact.update(sources: [*contact.sources, *(params["sources"] || [])].uniq)
    head :ok
  end
end