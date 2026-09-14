class Api::McpWriteController < ApiController
  skip_before_action :verify_authenticity_token
  before_action :check_mcp_key_configured!
  before_action :check_private_api_key!

  def handle
    Rails.logger.info("[Mcp::WriteServer] #{request.method} /api/mcp/write from #{request.remote_ip}")

    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      Mcp::WriteServer.build,
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

  private

  def check_mcp_key_configured!
    if Stacks::Utils.config.dig(:stacks, :private_api_key).to_s.strip.empty?
      raise Stacks::Errors::Unauthorized.new('MCP API key not configured')
    end
  end
end
