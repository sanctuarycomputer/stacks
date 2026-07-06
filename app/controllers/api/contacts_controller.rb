class Api::ContactsController < ApiController
  skip_before_action :verify_authenticity_token

  def index
    check_private_api_key!
    source = params[:source].to_s.strip
    if source.blank?
      render json: { error: "source query parameter is required" }, status: :bad_request
      return
    end

    contacts = Contact.where("? = ANY(sources)", source).order(:email)
    render json: contacts, each_serializer: Api::ContactSerializer
  end

  def create
    check_private_api_key!
    contact = Contact.create_or_find_by!(email: params["email"].downcase)
    contact.update(
      sources: [*contact.sources, *(params["sources"] || [])].uniq,
      metadata: contact.metadata.deep_merge(api_contact_metadata_blob)
    )
    head :ok
  end

  private

  def api_contact_metadata_blob
    payload = api_contact_request_payload_hash
    raw_meta = payload["metadata"] || payload[:metadata]
    hash =
      case raw_meta
      when ActionController::Parameters
        raw_meta.to_unsafe_h
      when Hash
        raw_meta
      else
        {}
      end
    hash.deep_stringify_keys
  end

  def api_contact_request_payload_hash
    raw = params.to_unsafe_h.except("controller", "action", "format")
    nested = raw["contact"] || raw[:contact]
    if nested.is_a?(Hash) || nested.is_a?(ActionController::Parameters)
      inner = nested.respond_to?(:to_unsafe_h) ? nested.to_unsafe_h : nested
      raw.except("contact", :contact).merge(inner)
    else
      raw.except("contact", :contact)
    end
  end
end
