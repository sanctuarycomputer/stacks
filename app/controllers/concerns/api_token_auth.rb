# Who is calling the Stacks API, and what may they do? One place for the legacy shared key and scoped tokens.
#
# A request presents X-Api-Key. A value starting "stk_" is a scoped ApiToken; anything else is compared with the
# legacy shared key (credentials stacks.private_api_key), in constant time either way.
#
# The legacy key keeps READ access. Its WRITE access is a deprecation switch: on until Stacksbot moves to its
# write token, then turned off with STACKS_LEGACY_KEY_WRITE=off (a config change, no deploy).
module ApiTokenAuth
  extend ActiveSupport::Concern

  Principal = Struct.new(:kind, :token, :scopes, keyword_init: true) do
    def legacy?
      kind == :legacy
    end

    def scope?(scope)
      scopes.include?(scope)
    end
  end

  LEGACY_READ_SCOPES = ["mcp:read"].freeze

  def self.legacy_key_can_write?
    ENV.fetch("STACKS_LEGACY_KEY_WRITE", "on").to_s.strip.downcase != "off"
  end

  def self.legacy_scopes
    legacy_key_can_write? ? ApiToken::SCOPES.keys : LEGACY_READ_SCOPES
  end

  private

  def api_principal
    @api_principal ||= resolve_api_principal
  end

  def resolve_api_principal
    provided = ApiKeyVault.read(request)
    if provided.start_with?(ApiToken::PREFIX)
      token = ApiToken.authenticate(provided)
      return token ? Principal.new(kind: :token, token: token, scopes: token.scopes) : nil
    end
    expected = Stacks::Utils.config.dig(:stacks, :private_api_key).to_s
    return nil if expected.strip.empty?
    return nil unless ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    Principal.new(kind: :legacy, token: nil, scopes: ApiTokenAuth.legacy_scopes)
  end

  # For logs: who called, never the secret itself (a token is named by its name and 12-char prefix).
  def api_principal_label
    p = api_principal
    return "nobody" unless p
    p.legacy? ? "the legacy key" : "token #{p.token.name.inspect} (#{p.token.token_prefix}…)"
  end

  # Raise Unauthorized (rendered 403) unless the caller holds at least one of `scopes`.
  def require_api_scope!(*scopes)
    p = api_principal
    raise Stacks::Errors::Unauthorized.new("Invalid API Key") unless p
    return p if scopes.flatten.any? { |s| p.scope?(s) }
    raise Stacks::Errors::Unauthorized.new("This key is not allowed to do that")
  end
end
