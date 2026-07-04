module Mcp
  module Responses
    def self.error(message)
      MCP::Tool::Response.new([{ type: 'text', text: { error: message }.to_json }])
    end

    def self.ok(payload)
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
