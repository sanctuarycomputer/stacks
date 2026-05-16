module ContributorPayouts
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
  # - Only three buckets have specific QBO account names today: commission,
  #   AL surplus, and PL surplus. The other three (IC, AL base, PL base)
  #   route to the host's legacy `find_qbo_account!` result (currently
  #   "Contractors - Client Services" with a studio sub-cat, with the
  #   internal-client Marketing Services override preserved).
  # - When a bucket's specific QBO account is missing from the qbo_accounts
  #   list, that one line falls back to the default account.
  #
  # No QBO API calls happen inside this class.
  class QboBillLines
    ROLE_LABEL_BY_BUCKET = {
      individual_contributor:  "Individual Contributor",
      account_lead_base:       "Account Lead",
      account_lead_surplus:    "Account Lead Surplus",
      project_lead_base:       "Project Lead",
      project_lead_surplus:    "Project Lead Surplus",
      commission:              "Commission",
    }.freeze

    # Buckets that map to a specific QBO account by chart-of-accounts
    # number. Matching by `acct_num` (rather than `name`) is more stable —
    # finance teams rename accounts more often than they renumber them.
    # Buckets not listed here fall back to the host's
    # `find_qbo_account!` result.
    SPECIFIC_ACCT_NUM_BY_BUCKET = {
      account_lead_surplus:  "5710",  # Bonuses
      project_lead_surplus:  "5710",  # Bonuses
      commission:            "6120",  # Commissions
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
          "ContributorPayouts::QboBillLines: per-bucket sums drifted from cp.amount " \
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
      target_num = SPECIFIC_ACCT_NUM_BY_BUCKET[bucket]
      return default_account if target_num.nil?
      qbo_accounts.find { |a| a.respond_to?(:acct_num) && a.acct_num == target_num } || default_account
    end

    def default_account
      @default_account ||= cp.find_qbo_account!(qbo_accounts).first
    end
  end
end
