module ContributorPayouts
  # Pure compute for the multi-line QBO Bill that ContributorPayout pushes.
  #
  # Given a ContributorPayout (and optionally an injected resolver — tests
  # pass a fake), returns an Array of
  #   { amount:, description:, account: }
  # Hashes — `account` is a QboChartAccount — that the caller turns into
  # Quickbooks::Model::BillLineItem instances.
  #
  # Lines are grouped per (role bucket × project tracker): every blueprint
  # entry carries blueprint_metadata.forecast_project, which locates a
  # ProjectTracker among invoice_tracker.project_trackers (same lookup as
  # ContributorPayout#calculate_surplus). Entries with no resolvable
  # tracker group into a per-bucket nil-tracker line. Each line's account
  # comes from Qbo::BillAccountResolver, so project-tracker-level mappings
  # (e.g. internal projects → Marketing) apply per line.
  #
  # Behavior preserved from the pre-engine version:
  # - When `cp.in_sync?` is false (blueprint sums disagree with cp.amount),
  #   collapses to a single line resolved as payout_individual_contributor
  #   with no tracker, so we never push a multi-line bill whose total can't
  #   be trusted.
  # - When the per-line sums drift from cp.amount (belt-and-suspenders
  #   after in_sync?), logs a WARN and collapses the same way.
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

    LINE_ITEM_KEY_BY_BUCKET = {
      individual_contributor:  "payout_individual_contributor",
      account_lead_base:       "payout_account_lead_base",
      account_lead_surplus:    "payout_account_lead_surplus",
      project_lead_base:       "payout_project_lead_base",
      project_lead_surplus:    "payout_project_lead_surplus",
      commission:              "payout_commission",
    }.freeze

    # Fallback marker for historical blueprints that pre-date the
    # AccountLeadSurplus / ProjectLeadSurplus first-class arrays. New
    # blueprints (post InvoiceTracker#make_contributor_payouts! change)
    # write surplus entries to their own keys; we only sniff
    # description_line for entries still living in the mixed
    # AccountLead / ProjectLead arrays.
    SURPLUS_DESCRIPTION_MARKER = "surplus revenue".freeze

    def initialize(contributor_payout, resolver: nil)
      @cp = contributor_payout
      @resolver = resolver || Qbo::BillAccountResolver.new(contributor_payout.enterprise)
    end

    def call
      return single_line unless cp.in_sync?

      buckets = bucket_blueprint(cp.blueprint || {})

      lines = ROLE_LABEL_BY_BUCKET.keys.each_with_object([]) do |bucket, acc|
        entries = buckets[bucket]
        next if entries.blank?

        entries.group_by { |e| tracker_for(e) }.each do |tracker, group|
          amount = group.sum { |e| e["amount"].to_f }.round(2)
          next if amount.zero?

          acc << {
            amount: amount,
            description: build_description(bucket, group),
            account: account_for(bucket, tracker),
          }
        end
      end

      return single_line if lines.empty?

      # Per-tracker splitting can surface a negative group that the old
      # whole-bucket sum used to net out (e.g. a credit line's entries on
      # one tracker). QBO rejects negative line amounts, so collapse to the
      # trusted single-line shape instead of pushing a doomed bill.
      if lines.any? { |l| l[:amount].negative? }
        Rails.logger.warn(
          "ContributorPayouts::QboBillLines: negative per-(bucket x tracker) line " \
          "(cp_id=#{cp.id}); falling back to single-line bill"
        )
        return single_line
      end

      if lines.sum { |l| l[:amount] }.round(2) != cp.amount.to_f.round(2)
        Rails.logger.warn(
          "ContributorPayouts::QboBillLines: per-line sums drifted from cp.amount " \
          "(cp_id=#{cp.id}, cp.amount=#{cp.amount}, line_sum=#{lines.sum { |l| l[:amount] }}); " \
          "falling back to single-line bill"
        )
        return single_line
      end

      lines
    end

    private

    attr_reader :cp, :resolver

    def single_line
      [{
        amount: cp.amount,
        description: cp.bill_description,
        account: resolver.account_for("payout_individual_contributor", contributor: cp.contributor),
      }]
    end

    def bucket_blueprint(blueprint)
      buckets = ROLE_LABEL_BY_BUCKET.keys.each_with_object({}) { |k, h| h[k] = [] }

      Array(blueprint["IndividualContributor"]).each { |e| buckets[:individual_contributor] << e }
      Array(blueprint["Commission"]).each            { |e| buckets[:commission] << e }

      # First-class surplus arrays (new shape from make_contributor_payouts!).
      Array(blueprint["AccountLeadSurplus"]).each { |e| buckets[:account_lead_surplus] << e }
      Array(blueprint["ProjectLeadSurplus"]).each { |e| buckets[:project_lead_surplus] << e }

      # Historical shape: AL / PL arrays mix base and surplus, only
      # distinguishable by SURPLUS_DESCRIPTION_MARKER in description_line.
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

    def tracker_for(entry)
      fp_id = entry.is_a?(Hash) ? entry.dig("blueprint_metadata", "forecast_project") : nil
      return nil if fp_id.blank?
      project_trackers.find { |pt| pt.forecast_project_ids.include?(fp_id) }
    end

    def project_trackers
      @project_trackers ||= cp.invoice_tracker.project_trackers
    end

    def build_description(bucket, entries)
      role_header = "# #{ROLE_LABEL_BY_BUCKET.fetch(bucket)}"
      lines = entries.map { |e| e["description_line"].to_s }
      ([role_header] + lines + [cp.bill_description]).join("\n")
    end

    def account_for(bucket, tracker)
      key = LINE_ITEM_KEY_BY_BUCKET.fetch(bucket)
      @account_cache ||= {}
      @account_cache[[key, tracker&.id]] ||=
        resolver.account_for(key, contributor: cp.contributor, project_tracker: tracker)
    end
  end
end
