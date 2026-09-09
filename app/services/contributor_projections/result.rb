module ContributorProjections
  Result = Struct.new(:horizon, :lines, :skipped, :skipped_details, :as_of, keyword_init: true) do
    # { ledger_id => { Date => [Line] } }
    def by_ledger_month
      lines.group_by(&:ledger_id).transform_values { |ls| ls.group_by(&:month) }
    end

    # { Date => summary } for every horizon month, across the contributor's
    # ledgers or just one of them.
    def by_contributor_month(contributor, ledger: nil)
      subset = lines.select { |l| l.contributor_id == contributor.id && (ledger.nil? || l.ledger_id == ledger.id) }
      month_index(subset)
    end

    # { enterprise_id => { Date => summary } }
    def by_enterprise_month
      lines.group_by(&:enterprise_id).transform_values { |ls| month_index(ls) }
    end

    # { Date => summary }, optionally for one enterprise.
    def totals_by_month(enterprise_id: nil)
      month_index(scope_to_enterprise(enterprise_id))
    end

    # { contributor_id => { Date => summary } }, optionally for one enterprise.
    def by_contributor_totals(enterprise_id: nil)
      scope_to_enterprise(enterprise_id).group_by(&:contributor_id).transform_values { |ls| month_index(ls) }
    end

    # Lazy, once per Result: the views need names and links.
    def contributors
      @contributors ||= Contributor.where(id: lines.map(&:contributor_id).uniq).includes(:forecast_person).index_by(&:id)
    end

    def stale?(today = Date.today)
      ContributorProjections.stale?(as_of, today: today)
    end

    def skipped_total
      (skipped || {}).values.sum
    end

    private

    def scope_to_enterprise(enterprise_id)
      enterprise_id ? lines.select { |l| l.enterprise_id == enterprise_id } : lines
    end

    def month_index(ls)
      horizon.month_keys.index_with { |m| summarize(ls.select { |l| l.month == m }) }
    end

    def summarize(ls)
      sorted = ls.sort_by { |l| [l.tentative ? 1 : 0, l.project_tracker_name.to_s, KIND_ORDER.index(l.kind) || 99] }
      {
        lines: sorted,
        amount: ls.sum(&:amount).round(2),
        confirmed_amount: ls.reject(&:tentative).sum(&:amount).round(2),
        tentative_amount: ls.select(&:tentative).sum(&:amount).round(2),
        hours: ls.select { |l| HOURS_KINDS.include?(l.kind) }.sum { |l| l.hours.to_f }.round(2),
      }
    end
  end
end
