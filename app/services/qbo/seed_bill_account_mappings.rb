module Qbo
  # One-time, idempotent seeding of QboBillAccountMapping rows that
  # reproduce the legacy hard-coded account routing. Run via
  #   rake stacks:seed_qbo_bill_account_mappings
  # after deploying the mapping engine. Safe to re-run: existing rows are
  # never modified, only missing ones created.
  #
  # Reproduces (per enterprise with a connected QboAccount):
  # - Entity defaults: the five contractor-services kinds → "Contractors -
  #   Client Services"; surpluses → acct 5710; commission → 6120;
  #   profit_share → acct 2340 (falling back to the contractor default,
  #   matching ProfitShare's legacy fallback); pay_stub → "Facilities
  #   Management Salaries".
  # - Contributor-level snapshot of studio routing (the deleted
  #   Studio#qbo_subcontractors_categories): contributors whose studio has
  #   an accounting_prefix get the five contractor-services kinds mapped to
  #   "Contractors - <first prefix>" (garden3d: "Total [SC] Subcontractors").
  # - Project-tracker-level Marketing routing for trackers whose forecast
  #   clients are all internal to the enterprise (the deleted
  #   ContributorPayout#find_qbo_account! internal-client override).
  #
  # Accounts missing from the mirror are skipped and reported. A skipped
  # ENTITY DEFAULT means that line kind fails strictly at sync time (the
  # agreed behavior); skipped contributor/tracker overrides just fall
  # through to the next resolution level, matching legacy semantics.
  #
  # Mixed-client trackers (internal AND external forecast clients) get NO
  # Marketing row: legacy routed per invoice tracker (one client each), a
  # per-project-tracker mapping can't express that split, and routing the
  # external share to Marketing would be worse than falling back.
  class SeedBillAccountMappings
    CONTRACTOR_SERVICES_KEYS = %w[
      payout_individual_contributor
      payout_account_lead_base
      payout_project_lead_base
      trueup
      contributor_adjustment
    ].freeze

    INTERNAL_CLIENT_KEYS = %w[
      payout_individual_contributor
      payout_account_lead_base
      payout_project_lead_base
    ].freeze

    def self.call(sync_chart_accounts: true)
      Enterprise.all.map do |enterprise|
        new(enterprise, sync_chart_accounts: sync_chart_accounts).call
      rescue => e
        # A dead OAuth token on one realm must not abort seeding the rest.
        # Re-running the task is safe (idempotent), so capture and move on.
        { enterprise: enterprise.name, created: 0, skipped: [], error: "#{e.class}: #{e.message}" }
      end
    end

    def initialize(enterprise, sync_chart_accounts: true)
      @enterprise = enterprise
      @sync_chart_accounts = sync_chart_accounts
      @created = 0
      @skipped = []
    end

    def call
      qa = enterprise.qbo_account
      if qa.nil?
        return { enterprise: enterprise.name, created: 0, skipped: ["no connected QboAccount"] }
      end

      qa.sync_all_chart_accounts! if @sync_chart_accounts
      @chart = QboChartAccount.active.where(qbo_account_id: qa.id).to_a

      seed_entity_defaults
      seed_contributor_studio_snapshots
      seed_internal_project_trackers

      { enterprise: enterprise.name, created: @created, skipped: @skipped }
    end

    private

    attr_reader :enterprise

    def by_name(name)
      @chart.find { |a| a.name == name }
    end

    def by_acct_num(num)
      @chart.find { |a| a.acct_num == num }
    end

    def seed_entity_defaults
      client_services = by_name("Contractors - Client Services")
      CONTRACTOR_SERVICES_KEYS.each { |key| upsert(key, client_services) }

      # Legacy parity: QboBillLines fell back to the contractor default when
      # the specific acct_num was missing from the realm.
      bonuses = by_acct_num("5710") || client_services
      upsert("payout_account_lead_surplus", bonuses)
      upsert("payout_project_lead_surplus", bonuses)
      upsert("payout_commission", by_acct_num("6120") || client_services)

      # Legacy parity: ProfitShare fell back to the contractor default when
      # acct 2340 was missing from the realm.
      upsert("profit_share", by_acct_num("2340") || client_services)
      upsert("pay_stub", by_name("Facilities Management Salaries"))
    end

    def seed_contributor_studio_snapshots
      Contributor.find_each do |contributor|
        studio = contributor.forecast_person&.studio
        next if studio.nil?

        account = studio_account(studio)
        next if account.nil?

        CONTRACTOR_SERVICES_KEYS.each { |key| upsert(key, account, contributor: contributor) }
      end
    end

    # Inlined from the deleted Studio#qbo_subcontractors_categories: the
    # studio's first accounting_prefix entry names its contractor expense
    # account; garden3d used a hard-coded rollup name.
    def studio_account(studio)
      return by_name("Total [SC] Subcontractors") if studio.is_garden3d?

      prefix = studio.accounting_prefix.to_s.split(",").map(&:strip).first
      return nil if prefix.blank?
      by_name("Contractors - #{prefix}")
    end

    def seed_internal_project_trackers
      marketing = by_name("Contractors - Marketing Services")
      if marketing.nil?
        @skipped << "internal project trackers: 'Contractors - Marketing Services' not in mirror"
        return
      end

      ProjectTracker.includes(forecast_projects: :forecast_client).find_each do |pt|
        clients = pt.forecast_projects.map(&:forecast_client).compact.uniq
        next if clients.empty?
        next unless clients.all? { |c| c.enterprise_forecast_client&.enterprise_id == enterprise.id }

        INTERNAL_CLIENT_KEYS.each { |key| upsert(key, marketing, project_tracker: pt) }
      end
    end

    def upsert(key, chart_account, contributor: nil, project_tracker: nil)
      if chart_account.nil?
        subject =
          if contributor
            " (contributor ##{contributor.id})"
          elsif project_tracker
            " (tracker ##{project_tracker.id})"
          else
            ""
          end
        @skipped << "#{key}#{subject}: account not found in mirror"
        return
      end

      existing = QboBillAccountMapping.find_by(
        enterprise_id: enterprise.id,
        line_item_key: key,
        contributor_id: contributor&.id,
        project_tracker_id: project_tracker&.id,
      )
      return if existing.present?

      QboBillAccountMapping.create!(
        enterprise: enterprise,
        line_item_key: key,
        contributor: contributor,
        project_tracker: project_tracker,
        qbo_chart_account_qbo_id: chart_account.qbo_id,
      )
      @created += 1
    end
  end
end
