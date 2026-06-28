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
      [single_line(:subcontractor)] # replaced in Task 4
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
