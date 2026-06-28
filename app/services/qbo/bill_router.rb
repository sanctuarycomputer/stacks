module Qbo
  # The single source of truth for "given this ledger item, what QBO bill lines
  # does it become, and which account does each line land in?"
  #
  #   Qbo::BillRouter.new(item, accounts_cache: cache).lines
  #   # => [ { amount:, description:, account: }, ... ]
  #
  # Two internal layers:
  #   1. Routing  (#concept_lines)  — pure: item -> [{amount, description, concept}]
  #   2. Resolution (#resolve)      — concept -> concrete QBO account by GL code
  class BillRouter
    # Concepts whose missing account falls back to :subcontractor_default rather
    # than raising. Everything else (subcontractor_default, marketing, salaries,
    # profit_share_liability) raises when absent — silently misrouting payroll or
    # a liability is worse than failing the sync.
    FALLBACKABLE_CONCEPTS = %i[subcontractor bonuses commission].freeze

    # Stable enterprise key -> concept -> GL code. The known real codes are
    # bonuses (5710), commission (6120), profit_share_liability (2340). All "____"
    # entries are placeholders filled from live data in Task 9. Per-studio
    # subcontractor codes are nested under :subcontractor_by_studio.
    CONCEPT_GL_BY_ENTERPRISE = {
      sanctuary: {
        subcontractor_default:  "____",
        marketing:              "____",
        salaries:               "____",
        bonuses:                "5710",
        commission:             "6120",
        profit_share_liability: "2340",
        subcontractor_by_studio: {
          # "<studio name>" => "<gl code>",
        },
      },
      garden3d: {
        subcontractor_default:  "____",
        marketing:              "____",
        salaries:               "____",
        bonuses:                "____",
        commission:             "____",
        profit_share_liability: "____",
        subcontractor_by_studio: {
          # garden3d routes all subcontractors to one account today.
        },
      },
    }.freeze

    ENTERPRISE_KEY_BY_NAME = {
      Enterprise::SANCTUARY_NAME => :sanctuary,
      Enterprise::GARDEN3D_NAME  => :garden3d,
    }.freeze

    ROLE_LABEL_BY_BUCKET = {
      individual_contributor: "Individual Contributor",
      account_lead_base:      "Account Lead",
      account_lead_surplus:   "Account Lead Surplus",
      project_lead_base:      "Project Lead",
      project_lead_surplus:   "Project Lead Surplus",
      commission:             "Commission",
    }.freeze

    SURPLUS_DESCRIPTION_MARKER = "surplus revenue".freeze

    def initialize(item, accounts_cache:)
      @item = item
      @accounts_cache = accounts_cache
    end

    def resolve(concept)
      gl = gl_code_for(concept)
      account = gl && find_account(gl)
      return account if account

      if FALLBACKABLE_CONCEPTS.include?(concept)
        fallback = find_account(gl_code_for(:subcontractor_default))
        return fallback if fallback
      end

      raise "Qbo::BillRouter: no account for concept #{concept.inspect} " \
            "(gl #{gl.inspect}) in enterprise #{enterprise.name.inspect}"
    end

    def concept_lines
      case item
      when PayStub
        [single_line(:salaries)]
      when ProfitShare
        [single_line(:profit_share_liability)]
      when ContributorPayout
        payout_concept_lines
      else # Trueup, ContributorAdjustment
        [single_line(:subcontractor)]
      end
    end

    private

    attr_reader :item

    def single_line(concept)
      { amount: item.amount, description: item.bill_description, concept: concept }
    end

    def payout_concept_lines
      return [collapsed_payout_line] unless item.in_sync?

      buckets = bucket_blueprint(item.blueprint || {})

      lines = ROLE_LABEL_BY_BUCKET.keys.each_with_object([]) do |bucket, acc|
        entries = buckets[bucket]
        next if entries.blank?

        amount = entries.sum { |e| e["amount"].to_f }.round(2)
        next if amount.zero?

        acc << {
          amount: amount,
          description: build_bucket_description(bucket, entries),
          concept: concept_for_bucket(bucket),
        }
      end

      return [collapsed_payout_line] if lines.empty?

      if lines.sum { |l| l[:amount] }.round(2) != item.amount.to_f.round(2)
        Rails.logger.warn(
          "Qbo::BillRouter: per-bucket sums drifted from cp.amount " \
          "(cp_id=#{item.id}, cp.amount=#{item.amount}, " \
          "bucket_sum=#{lines.sum { |l| l[:amount] }}); falling back to single-line bill"
        )
        return [collapsed_payout_line]
      end

      lines
    end

    def collapsed_payout_line
      { amount: item.amount, description: item.bill_description, concept: base_concept }
    end

    def concept_for_bucket(bucket)
      case bucket
      when :account_lead_surplus, :project_lead_surplus then :bonuses
      when :commission then :commission
      else base_concept
      end
    end

    # base_concept is :subcontractor here; Task 5 adds the internal-client
    # :marketing override.
    def base_concept
      :subcontractor
    end

    def bucket_blueprint(blueprint)
      buckets = ROLE_LABEL_BY_BUCKET.keys.each_with_object({}) { |k, h| h[k] = [] }

      Array(blueprint["IndividualContributor"]).each { |e| buckets[:individual_contributor] << e }
      Array(blueprint["Commission"]).each            { |e| buckets[:commission] << e }
      Array(blueprint["AccountLeadSurplus"]).each    { |e| buckets[:account_lead_surplus] << e }
      Array(blueprint["ProjectLeadSurplus"]).each    { |e| buckets[:project_lead_surplus] << e }

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

    def build_bucket_description(bucket, entries)
      role_header = "# #{ROLE_LABEL_BY_BUCKET.fetch(bucket)}"
      entry_lines = entries.map { |e| e["description_line"].to_s }
      ([role_header] + entry_lines + [item.bill_description]).join("\n")
    end

    def gl_code_for(concept)
      if concept == :subcontractor
        studio && enterprise_gl_map[:subcontractor_by_studio]&.fetch(studio.name, nil)
      else
        enterprise_gl_map[concept]
      end
    end

    def find_account(gl)
      return nil if gl.nil?
      accounts.find { |a| a.respond_to?(:acct_num) && a.acct_num == gl }
    end

    def accounts
      @accounts ||= @accounts_cache.accounts_for(qbo_account)
    end

    def enterprise_gl_map
      key = ENTERPRISE_KEY_BY_NAME[enterprise.name]
      raise "Qbo::BillRouter: unknown enterprise #{enterprise.name.inspect}" if key.nil?
      CONCEPT_GL_BY_ENTERPRISE.fetch(key)
    end

    def ledger
      item.ledger
    end

    def enterprise
      ledger.enterprise
    end

    def contributor
      ledger.contributor
    end

    def qbo_account
      enterprise.qbo_account
    end

    def studio
      contributor&.forecast_person&.studio
    end
  end
end
