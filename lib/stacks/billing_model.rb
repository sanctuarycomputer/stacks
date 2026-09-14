# The payout split rules for a ProjectTracker. One entry per rate card /
# deal structure; ProjectTracker#billing_model names the entry.
#
#   treasury_share      — what the company keeps off a client-work line
#   account_lead_share  — Account Lead's cut of the post-commission line
#   project_lead_share  — Project Lead's cut of the post-commission line
#   surplus_lead_share  — each lead's cut of any surplus on a line
#   ic_ceiling          — 1 - treasury - AL - PL: the IC's maximum share
#   surplus_threshold   — treasury + AL + PL: margin above which surplus exists
#
# Shares are BigDecimal so `1 - treasury_share` is exact. Coerce to Float only
# when writing into a jsonb blueprint.
module Stacks::BillingModel
  Rules = Struct.new(:name, :treasury_share, :account_lead_share, :project_lead_share, :surplus_lead_share, keyword_init: true) do
    def ic_ceiling
      1 - treasury_share - account_lead_share - project_lead_share
    end

    def surplus_threshold
      treasury_share + account_lead_share + project_lead_share
    end

    # The IC's share of a line given which leads are actually assigned this
    # month. Mirrors the inline arithmetic the payout builder used to do.
    def ic_share(account_lead:, project_lead:)
      1 - treasury_share - (account_lead ? account_lead_share : 0) - (project_lead ? project_lead_share : 0)
    end

    # The surplus a single line generates, in dollars: the slice of the line's
    # profit margin that sits above this model's threshold. The one place the
    # formula lives — both the real payout builder (ContributorPayout#
    # calculate_surplus) and the projection (ContributorProjections::Build)
    # price surplus through it, so they cannot drift apart.
    #
    # Returns a Float: shares are BigDecimal, but surplus amounts land in a
    # jsonb blueprint, where a BigDecimal would serialize as the string
    # "0.42e2" rather than a number. Zero unless BOTH amounts are positive —
    # there is no surplus on an unbilled line, and none on a line the IC was
    # never actually paid for.
    def surplus_for(working_amount:, ic_amount:)
      working = working_amount.to_f
      ic = ic_amount.to_f
      return 0.0 unless working > 0 && ic > 0

      margin = (working - ic) / working
      [((margin - surplus_threshold) * working).round(2), 0.0].max.to_f
    end

    def label
      "#{name} — #{(treasury_share * 100).to_i}% treasury, #{(ic_ceiling * 100).to_i}% IC ceiling"
    end
  end

  ALL = {
    "new_deal_v1" => Rules.new(
      name: "new_deal_v1",
      treasury_share: BigDecimal("0.30"),
      account_lead_share: BigDecimal("0.08"),
      project_lead_share: BigDecimal("0.05"),
      surplus_lead_share: BigDecimal("0.15"),
    ).freeze,
    "new_deal_v2" => Rules.new(
      name: "new_deal_v2",
      treasury_share: BigDecimal("0.33"),
      account_lead_share: BigDecimal("0.08"),
      project_lead_share: BigDecimal("0.05"),
      surplus_lead_share: BigDecimal("0.15"),
    ).freeze,
  }.freeze

  DEFAULT = "new_deal_v1".freeze

  def self.for(name)
    ALL.fetch(name.to_s) { raise ArgumentError, "unknown billing model #{name.inspect}" }
  end

  def self.names
    ALL.keys
  end
end
