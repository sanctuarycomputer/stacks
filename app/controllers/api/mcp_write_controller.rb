class Api::McpWriteController < ApiController
  skip_before_action :verify_authenticity_token
  include ApiTokenAuth
  # Scoped tokens (ApiToken) or the legacy shared key; see ApiTokenAuth.
  before_action -> { require_api_scope!(Mcp::WriteServer::WRITE_SCOPES) }

  def handle
    Rails.logger.info("[Mcp::WriteServer] #{request.method} /api/mcp/write from #{request.remote_ip} as #{api_principal_label}")

    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      Mcp::WriteServer.build(scopes: api_principal.scopes),
      stateless: true,
      enable_json_response: true
    )

    # Rewind in case Rails consumed the body during parameter parsing.
    request.body.rewind
    status, headers, body = transport.handle_request(request)

    body_str = body.first
    if body_str
      render json: body_str, status: status
    else
      head status
    end
  end

end
