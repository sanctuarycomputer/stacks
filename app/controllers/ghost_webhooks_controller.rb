#
# Receiver for Ghost member webhooks (member.added / member.edited /
# member.deleted). Ghost aborts delivery after 2s and does not retry, so this
# handler must be fast, and errors return 200 — the 10-minute reconciliation
# sweep (Stacks::GhostSync) is the correctness backstop. A non-2xx buys
# nothing, and a 410 would permanently delete the webhook on the Ghost side.
class GhostWebhooksController < ActionController::Base
  skip_before_action :verify_authenticity_token, raise: false

  TIMESTAMP_TOLERANCE_MS = 5.minutes.in_milliseconds

  def handle
    return head :unauthorized unless valid_signature?

    payload = parsed_payload
    member = payload["member"] || {}
    current = member["current"] || {}
    previous = member["previous"] || {}

    sync = Stacks::GhostSync.new(Stacks::Ghost.new(max_retries: 0))
    if current["id"].present?
      # member.added and member.edited are handled identically: the upsert is
      # idempotent, so our own outbound writes echoing back are no-ops.
      sync.upsert_contact_from_member(current)
    elsif previous["id"].present?
      sync.handle_member_deleted(previous)
    end
    head :ok
  rescue => e
    Rails.logger.error("[ghost-webhook] #{e.class}: #{e.message}")
    head :ok
  end

  private

  def parsed_payload
    JSON.parse(request.raw_post)
  rescue JSON::ParserError
    {}
  end

  def webhook_secret
    Stacks::Utils.config.dig(:ghost, :webhook_secret).to_s
  end

  # X-Ghost-Signature: sha256=<hex>, t=<ms> — hex is HMAC_SHA256 over the raw
  # request body with the millisecond timestamp string concatenated (Ghost 6
  # format). Compared constant-time; stale timestamps rejected (replay guard).
  def valid_signature?
    secret = webhook_secret
    return false if secret.blank?

    parts = request.headers["X-Ghost-Signature"].to_s
      .split(",").map(&:strip).map { |p| p.split("=", 2) }.select { |p| p.length == 2 }.to_h
    hex, ts = parts["sha256"], parts["t"]
    return false if hex.blank? || ts.blank?
    return false if (Time.current.to_f * 1000 - ts.to_i).abs > TIMESTAMP_TOLERANCE_MS

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post + ts)
    ActiveSupport::SecurityUtils.secure_compare(expected, hex)
  end
end
