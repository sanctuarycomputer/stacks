# Removes ("deactivates") Optix members who no longer hold any membership.
# Runs daily for Index Space via Enterprise#daily_tasks inside
# stacks:daily_enterprise_tasks.
#
# Selection rules — a user is removed when ALL hold (validated against the
# live API via a read-only dry run reviewed by the Index team; see
# docs/optix-member-deactivation-dry-run.md and the design spec in
# docs/superpowers/specs/2026-07-10-optix-deactivate-inactive-members-design.md):
#
#   1. is_active (they are a current Optix user)
#   2. at least one account plan on record (leads/contacts untouched)
#   3. no plan with status ACTIVE, IN_TRIAL, or UPCOMING — a scheduled
#      future plan is still membership
#   4. has_plans is false (Optix's own flag; catches team-held plans that
#      never appear under accountPlans.access_usage_user)
#   5. their latest plan that actually STARTED ended more than grace_days
#      ago (plans canceled before their start date never ran — their
#      canceled_timestamp is when the cancel was clicked, not a lapse date)
#   6. not an Optix admin
#   7. they can be mapped to a member_id AND memberRemovePreview succeeds;
#      otherwise they are skipped and reported, never removed blind
#
# Reads exclusively from the live API (not the synced optix_* tables) so it
# never acts on stale data. Idempotent: removed members return is_active:
# false and fail rule 1 on subsequent runs.
class Stacks::Optix::DeactivateInactiveMembers
  ACTIVE_PLAN_STATUSES = %w[ACTIVE IN_TRIAL UPCOMING].freeze
  DAY_IN_SECONDS = 86_400

  Result = Struct.new(:deactivated, :skipped, :errors, keyword_init: true)

  def self.call(client:, grace_days: 7, collect_payment: true)
    new(client: client, grace_days: grace_days, collect_payment: collect_payment).call
  end

  attr_reader :client, :grace_days, :collect_payment

  def initialize(client:, grace_days: 7, collect_payment: true)
    @client = client
    @grace_days = grace_days
    @collect_payment = collect_payment
  end

  def call
    result = Result.new(deactivated: [], skipped: [], errors: [])
    now = Time.now.to_i

    candidates = select_candidates(now)
    return log_summary(result) if candidates.empty?

    member_ids = client.user_id_to_member_id_map

    candidates.each do |user|
      process_candidate(user, member_ids, result)
    end

    log_summary(result)
  end

  private

  def select_candidates(now)
    # Dedupe against pagination drift: if Optix's user list shifts across
    # page boundaries mid-crawl, the same user can appear on two pages and
    # would otherwise be processed (removed) twice.
    users = client.list_users.uniq { |u| u["user_id"] }
    plans_by_user = client.list_account_plans.group_by { |p| p.dig("access_usage_user", "user_id") }
    cutoff = now - (grace_days * DAY_IN_SECONDS)

    users.select do |user|
      next false unless user["is_active"]
      next false if user["is_admin"]
      next false if user["has_plans"]

      user_plans = plans_by_user[user["user_id"]] || []
      next false if user_plans.empty?
      next false if user_plans.any? { |p| ACTIVE_PLAN_STATUSES.include?(p["status"]) }

      # Conservative guard: a started plan with NO end data (e.g. status
      # UNKNOWN — in the enum but intentionally not "membership") leaves us
      # unable to prove the membership lapsed. Never remove on ambiguity.
      started = user_plans.select { |p| p["start_timestamp"] && p["start_timestamp"] <= now }
      next false if started.any? { |p| p["end_timestamp"].nil? && p["canceled_timestamp"].nil? }

      last_end = last_membership_end(started)
      next false if last_end.nil?

      last_end <= cutoff
    end
  end

  # When did this user's membership actually lapse? Only plans that started
  # count (caller pre-filters); effective end is end_timestamp, else
  # canceled_timestamp. nil when no plan ever ran (caller skips — conservative).
  def last_membership_end(started)
    started.map { |p| p["end_timestamp"] || p["canceled_timestamp"] }.compact.max
  end

  def process_candidate(user, member_ids, result)
    user_id = user["user_id"]
    member_id = member_ids[user_id]

    if member_id.nil?
      result.skipped << skip(user, "no member_id mapping (no invoices on record)")
      return
    end

    begin
      preview = client.member_remove_preview(member_id)
    rescue => e
      result.skipped << skip(user, "memberRemovePreview failed: #{e.class}: #{e.message}")
      return
    end

    if preview.nil?
      result.skipped << skip(user, "memberRemovePreview returned no invoice preview")
      return
    end

    begin
      client.member_remove!(member_id, collect_payment: collect_payment)
    rescue => e
      result.errors << { user_id: user_id, email: user["email"], error: "#{e.class}: #{e.message}" }
      Rails.logger.error("[#{self.class.name}] memberRemove failed for #{user["email"]} (member_id=#{member_id}): #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      return
    end

    entry = {
      user_id: user_id,
      member_id: member_id,
      email: user["email"],
      name: [user["name"], user["surname"]].compact.join(" "),
      invoice_total: preview["total"],
    }
    result.deactivated << entry
    Rails.logger.info("[#{self.class.name}] deactivated #{entry[:email]} (user_id=#{user_id}, member_id=#{member_id}, invoice_total=#{entry[:invoice_total]})")
  end

  def skip(user, reason)
    Rails.logger.warn("[#{self.class.name}] skipped #{user["email"]} (user_id=#{user["user_id"]}): #{reason}")
    { user_id: user["user_id"], email: user["email"], reason: reason }
  end

  def log_summary(result)
    Rails.logger.info(
      "[#{self.class.name}] done: #{result.deactivated.length} deactivated, " \
      "#{result.skipped.length} skipped, #{result.errors.length} errored"
    )
    result
  end
end
