# A scoped credential for the Stacks API and MCP surfaces (roadmap Phase 7: "writes go through a separate MCP
# surface with a scoped token model").
#
# - Only a SHA-256 digest of the token is stored (the token is 256 bits of randomness, so a slow hash adds
#   nothing); the plaintext exists only in the response to #mint!, shown once to an admin.
# - Authentication looks the digest up by index and re-compares it in constant time.
# - Revocation and expiry are read from the row on every request (no caching), so they take effect at once.
# - Scopes are least privilege: a token can only do what its scopes name (SCOPES below).
class ApiToken < ApplicationRecord
  PREFIX = "stk_".freeze

  SCOPES = {
    "mcp:read" => "Read MCP tools (/api/mcp)",
    "mcp:write:resourcing" => "Write MCP: assignments, placeholders and recurring assignments",
    "mcp:write:projects" => "Write MCP: create and archive tentative projects",
    "mcp:write:trackers" => "Write MCP: project trackers, workstreams and their rates, roles, completion",
    "api:write:projections" => "Projected assignments API (/api/v1/projected_assignments)",
  }.freeze

  belongs_to :created_by, class_name: "AdminUser", optional: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validate :scopes_are_known

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end

  # Deploys land before migrations: without the table, tokens can't exist yet (legacy key only), never a crash.
  def self.available?
    return @available if @available
    @available = connection.data_source_exists?(table_name)
  rescue StandardError
    false
  end

  # Mint a token. Returns [record, plaintext]; the plaintext is never stored and can't be shown again.
  def self.mint!(name:, scopes:, created_by: nil, expires_at: nil)
    raw = "#{PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    record = create!(name: name, scopes: Array(scopes).reject(&:blank?), created_by: created_by, expires_at: expires_at,
                     token_digest: digest(raw), token_prefix: raw[0, 12])
    [record, raw]
  end

  # The active token for a presented plaintext, or nil. Constant-time on the digest.
  def self.authenticate(raw)
    return nil unless available?
    raw = raw.to_s
    return nil unless raw.start_with?(PREFIX)
    d = digest(raw)
    token = active.find_by(token_digest: d)
    return nil unless token && ActiveSupport::SecurityUtils.secure_compare(token.token_digest, d)
    token.touch_used!
    token
  end

  def scope?(scope)
    scopes.include?(scope)
  end

  def active?
    revoked_at.nil? && (expires_at.nil? || expires_at > Time.current)
  end

  def revoke!
    update!(revoked_at: Time.current) if revoked_at.nil?
  end

  # At most one write every 5 minutes per token: bookkeeping, not a hot path.
  def touch_used!
    return if last_used_at && last_used_at > 5.minutes.ago
    update_column(:last_used_at, Time.current)
  rescue StandardError
    nil
  end

  private

  def scopes_are_known
    unknown = Array(scopes) - SCOPES.keys
    errors.add(:scopes, "unknown: #{unknown.join(', ')}") if unknown.any?
    errors.add(:scopes, "choose at least one") if Array(scopes).empty?
  end
end
