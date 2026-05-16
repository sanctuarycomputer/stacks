# Pure compute for the multi-line QBO Bill that ContributorPayout pushes.
#
# Given a ContributorPayout and the QBO accounts list (typically the result
# of `qbo_account.fetch_all_accounts`), returns an Array of
#   { amount:, description:, account: }
# Hashes — one per non-zero bucket — that the caller turns into
# Quickbooks::Model::BillLineItem instances.
#
# Behavior:
# - When `cp.in_sync?` is false (blueprint sums disagree with cp.amount),
#   collapses to a single line at the default account so we never push a
#   multi-line bill whose total can't be trusted.
# - When the bucket-summed total drifts from cp.amount due to per-bucket
#   rounding (belt-and-suspenders after in_sync?), logs a WARN and
#   collapses to a single line.
# - When a bucket's specific QBO account is missing from the qbo_accounts
#   list, that one line falls back to the default account — other lines
#   keep their specific accounts.
#
# No QBO API calls happen inside this class.
class ContributorPayoutQboBillLines
  ROLE_LABEL_BY_BUCKET = {
    individual_contributor:  "Individual Contributor",
    account_lead_base:       "Account Lead",
    account_lead_surplus:    "Account Lead Surplus",
    project_lead_base:       "Project Lead",
    project_lead_surplus:    "Project Lead Surplus",
    commission:              "Commission",
  }.freeze

  # Substring in description_line that identifies a surplus-share entry
  # inside the mixed AccountLead / ProjectLead buckets in blueprint.
  SURPLUS_DESCRIPTION_MARKER = "surplus revenue".freeze

  def initialize(contributor_payout, qbo_accounts)
    @cp = contributor_payout
    @qbo_accounts = qbo_accounts
  end

  def call
    return single_line unless cp.in_sync?

    buckets = bucket_blueprint(cp.blueprint || {})

    lines = ROLE_LABEL_BY_BUCKET.keys.each_with_object([]) do |bucket, acc|
      entries = buckets[bucket]
      next if entries.blank?

      amount = entries.sum { |e| e["amount"].to_f }.round(2)
      next if amount.zero?

      acc << {
        amount: amount,
        description: build_description(bucket, entries),
        account: account_for_bucket(bucket),
      }
    end

    return single_line if lines.empty?

    if lines.sum { |l| l[:amount] }.round(2) != cp.amount.to_f.round(2)
      Rails.logger.warn(
        "ContributorPayoutQboBillLines: per-bucket sums drifted from cp.amount " \
        "(cp_id=#{cp.id}, cp.amount=#{cp.amount}, bucket_sum=#{lines.sum { |l| l[:amount] }}); " \
        "falling back to single-line bill"
      )
      return single_line
    end

    lines
  end

  private

  attr_reader :cp, :qbo_accounts

  def single_line
    [{
      amount: cp.amount,
      description: cp.bill_description,
      account: default_account,
    }]
  end

  def bucket_blueprint(blueprint)
    buckets = ROLE_LABEL_BY_BUCKET.keys.each_with_object({}) { |k, h| h[k] = [] }

    Array(blueprint["IndividualContributor"]).each { |e| buckets[:individual_contributor] << e }
    Array(blueprint["Commission"]).each            { |e| buckets[:commission] << e }

    Array(blueprint["AccountLead"]).each do |entry|
      bucket = surplus_entry?(entry) ? :account_lead_surplus : :account_lead_base
      buckets[bucket] << entry
    end

    Array(blueprint["ProjectLead"]).each do |entry|
      bucket = surplus_entry?(entry) ? :project_lead_surplus : :project_lead_base
      buckets[bucket] << entry
    end

    buckets
  end

  def surplus_entry?(entry)
    entry["description_line"].to_s.include?(SURPLUS_DESCRIPTION_MARKER)
  end

  def build_description(bucket, entries)
    role_header = "# #{ROLE_LABEL_BY_BUCKET.fetch(bucket)}"
    lines = entries.map { |e| e["description_line"].to_s }
    ([role_header] + lines + [cp.bill_description]).join("\n")
  end

  def account_for_bucket(bucket)
    studio = cp.contributor.forecast_person.studio
    studio_label = studio&.qbo_subcontractors_categories&.first
    return default_account if studio_label.nil?

    specific_name = "Contractors - #{ROLE_LABEL_BY_BUCKET.fetch(bucket)} - #{studio_label}"
    qbo_accounts.find { |a| a.name == specific_name } || default_account
  end

  def default_account
    @default_account ||= cp.find_qbo_account!(qbo_accounts).first
  end
end
