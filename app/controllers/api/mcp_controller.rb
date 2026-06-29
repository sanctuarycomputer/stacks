class Api::McpController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_private_api_key!

  def handle
    Rails.logger.info("[Mcp::Server] #{request.method} /api/mcp from #{request.remote_ip}")

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
