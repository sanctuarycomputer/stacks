class Api::McpController < ApiController
  skip_before_action :verify_authenticity_token
  include ApiTokenAuth
  # Scoped tokens (ApiToken) or the legacy shared key; see ApiTokenAuth.
  before_action -> { require_api_scope!("mcp:read") }

  def handle
    Rails.logger.info("[Mcp::Server] #{request.method} /api/mcp from #{request.remote_ip} as #{api_principal_label}")

    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      Mcp::Server.build,
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
