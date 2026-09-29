# The company-wide financial outlook behind the get_financial_outlook MCP tool. Read-only; one company (never
# split by studio or enterprise); aggregates only, and no person's name ever appears.
#
#   booked        — the next N months of the Runn plan (the forward schedule), priced as booked hours × project
#                   rate before discounts/caps. The rate is the linked Stacks tracker's Forecast project rate, else
#                   the default hourly rate (Runn rate cards are not synced). Time-and-materials projects only:
#                   fixed-price projects are NOT priced hourly — they are listed with their budget; non-billable
#                   work is left out. Placeholders and unconfirmed projects are tentative, apart from the total.
#                   A tracker with a monthly budget (a retainer) caps its project each month, and the cap is shown.
#   actuals       — the last N closed months of Income, accrual basis, from the g3d (whole-company) studio
#                   snapshot built from the QBO P&L.
#   target        — the g3d Income OKR target for the latest closed month, only if one is stored; never assumed.
#   spend         — company-wide spend by expense category (accrual, QBO P&L, every entity combined), the last N
#                   closed months vs the N before, with top movers. Categories merge across locations and account
#                   numbers. Payroll, benefits, contractors, payments to people and intercompany accounts are
#                   excluded (Stacks::PeopleCostAccounts). QBO bills are NOT used: nearly all of them are
#                   contributor payouts, so they say nothing about vendor spend.
# Cash and runway are cash-basis and stay in get_executive_dashboard (include_money).
class Stacks::FinancialOutlook
  BOOKED_BASIS = "Runn plan: booked hours × project rate, before discounts/caps; time-and-materials only (fixed-price listed, not priced); retainers capped at their monthly budget; tentative = placeholders and unconfirmed projects".freeze
  ACTUALS_BASIS = "accrual (QBO P&L, company-wide g3d snapshot)".freeze
  SPEND_BASIS = "accrual (QBO P&L expense and cost-of-goods accounts, all entities combined); excludes payroll, benefits, contractors, payments to people and intercompany".freeze
  SPEND_SECTIONS = ["Cost of Goods Sold", "Expenses", "Other Expenses"].freeze
  CASH_NOTE = "Cash and runway are cash-basis figures: see get_executive_dashboard (include_money).".freeze
  TOP_N = 5

  def initialize(today: Date.current, months: 3)
    @today = today
    @months = months.to_i.clamp(1, 6)
  end

  def call
    {
      as_of: @today.iso8601,
      booked: booked,
      actuals: actuals,
      target: target,
      spend: spend,
      cash: CASH_NOTE,
    }
  end

  # ---- booked ----------------------------------------------------------------------------------------------

  def future_months
    first = @today.beginning_of_month
    (0...@months).map { |i| first >> i }
  end

  def booked
    months = future_months
    range_start = [months.first, @today].max
    range_end = months.last.end_of_month
    assignments = RunnAssignment.includes(:runn_project)
      .where(is_active: true, is_template: false, is_non_working_day: false)
      .where("start_date <= ? AND end_date >= ?", range_end, range_start)
      .to_a
    trackers = ProjectTracker.where(runn_project_id: assignments.map(&:project_id).uniq).includes(:forecast_projects).index_by(&:runn_project_id)
    default_rate = System.instance.default_hourly_rate.to_f

    fixed_price = {}
    defaulted = Set.new
    by_month = months.map do |m|
      from = [m, @today].max
      to = m.end_of_month
      staffed = Hash.new(0.0)
      tentative = 0.0
      assignments.each do |a|
        project = a.runn_project
        next if project.nil? || project.is_template || !a.is_billable || project.pricing_model == "nb"
        next if a.end_date < from || a.start_date > to

        if project.pricing_model == "fp"
          fixed_price[project.runn_id] ||= { project: project.name, budget_usd: project.budget&.to_i }
          next
        end
        tracker = trackers[project.runn_id]
        rate = tracker&.forecast_projects&.first&.hourly_rate&.to_f
        defaulted << project.runn_id if rate.nil?
        value = hours(a, from, to) * (rate || default_rate)
        if a.is_placeholder || project.is_confirmed == false then tentative += value else staffed[project.runn_id] += value end
      end
      capped_by = 0.0
      staffed.each do |pid, v|
        cap = trackers[pid]&.monthly_budget? ? trackers[pid].monthly_budget_high_end.to_f : nil
        next unless cap && v > cap

        capped_by += v - cap
        staffed[pid] = cap
      end
      names = assignments.map(&:runn_project).compact.index_by(&:runn_id)
      {
        month: m.strftime("%Y-%m"),
        partial_from: (from > m ? from.iso8601 : nil),
        booked_usd: staffed.values.sum.round,
        retainer_cap_applied_usd: capped_by.round,
        tentative_usd: tentative.round,
        top_projects: staffed.sort_by { |pid, v| [-v, names[pid]&.name.to_s] }.first(TOP_N).map { |pid, v| { project: names[pid]&.name, booked_usd: v.round } },
      }.compact
    end
    {
      basis: BOOKED_BASIS,
      months: by_month,
      fixed_price_not_priced_hourly: fixed_price.values.sort_by { |f| f[:project].to_s },
      priced_at_default_rate_projects: defaulted.size,
    }
  end

  # Booked hours in [from, to]: minutes per day on weekdays (Runn plans working days).
  def hours(assignment, from, to)
    a = [assignment.start_date, from].max
    b = [assignment.end_date, to].min
    return 0.0 if a > b

    (a..b).count { |d| (1..5).cover?(d.wday) } * assignment.minutes_per_day / 60.0
  end

  # ---- actuals + target -----------------------------------------------------------------------------------

  def g3d
    @g3d ||= Studio.all.find { |s| s.mini_name.to_s.split(",").map(&:strip).any? { |m| m.casecmp?("g3d") } }
  end

  def closed_month_entries
    entries = Array(g3d&.snapshot.presence && g3d.snapshot["month"])
    entries.select { |e| (d = parse_date(e["period_ends_at"])) && d < @today }.sort_by { |e| parse_date(e["period_ends_at"]) }
  end

  def actuals
    rows = closed_month_entries.last(@months).map do |e|
      { month: parse_date(e["period_starts_at"])&.strftime("%Y-%m") || e["label"], income_usd: e.dig("accrual", "datapoints", "income", "value")&.to_f&.round }
    end
    { basis: ACTUALS_BASIS, months: rows, note: (rows.empty? ? "No closed month in the g3d snapshot yet." : nil) }.compact
  end

  def target
    entry = closed_month_entries.last
    okr_names = Okr.where(datapoint: Okr.datapoints[:income]).pluck(:name)
    hit = entry && okr_names.map { |n| entry.dig("accrual", "okrs", n) }.compact.find { |o| o["target"].present? }
    if hit
      { basis: "g3d Income OKR target, as stored for #{entry['label']} (accrual)", income_usd: hit["target"].to_f.round, health: hit["health"] }
    else
      { basis: "g3d Income OKR", income_usd: nil, note: "No income target is stored in Stacks OKRs." }
    end
  end

  # ---- spend by category -----------------------------------------------------------------------------------

  def spend
    last_months = (1..@months).map { |i| @today.beginning_of_month << i }.reverse
    prior_months = (1..@months).map { |i| last_months.first << i }.reverse
    last = category_totals(last_months)
    prior = category_totals(prior_months)
    missing = (last_months + prior_months).reject { |m| month_reports(m).any? }.map { |m| m.strftime("%Y-%m") }
    movers = (last.keys | prior.keys).map do |c|
      { category: c, last_usd: last[c].round, prior_usd: prior[c].round, change_usd: (last[c] - prior[c]).round }
    end
    {
      basis: SPEND_BASIS,
      last: { from: last_months.first.iso8601, to: last_months.last.end_of_month.iso8601, total_usd: last.values.sum.round },
      prior: { from: prior_months.first.iso8601, to: prior_months.last.end_of_month.iso8601, total_usd: prior.values.sum.round },
      change_pct: prior.values.sum.zero? ? nil : ((last.values.sum - prior.values.sum) / prior.values.sum * 100).round(1),
      top_movers: movers.reject { |m| m[:change_usd].zero? }.sort_by { |m| [-m[:change_usd].abs, m[:category]] }.first(TOP_N),
      months_without_a_p_and_l: missing.presence,
    }.compact
  end

  def month_reports(month)
    @month_reports ||= {}
    @month_reports[month] ||= QboProfitAndLossReport.where(starts_at: month, ends_at: month.end_of_month).to_a
  end

  # One category → accrual amount over these months, across every entity's P&L.
  def category_totals(months)
    totals = Hash.new(0.0)
    months.each do |m|
      month_reports(m).each do |report|
        each_spend_row(Array(report.data&.dig("accrual", "rows"))) { |category, value| totals[category] += value }
      end
    end
    totals
  end

  # Leaf rows inside the spend sections, with their parent headers; people-cost accounts dropped.
  def each_spend_row(rows)
    stack = []
    rows.each do |label, value|
      label = label.to_s
      if value.nil?
        stack.push(label)
      elsif label.start_with?("Total ")
        # Close the header this total names (QBO sometimes totals a header that was also a posting row).
        i = stack.rindex(label.delete_prefix("Total "))
        stack.slice!(i..) if i
      elsif SPEND_SECTIONS.include?(stack.first) && !Stacks::PeopleCostAccounts.excluded?(label, *stack.drop(1))
        yield category(label), value.to_f
      end
    end
  end

  # "[NYC] 6100 Software and Subscriptions" → "Software and Subscriptions": one company, not per location.
  def category(label)
    label.sub(/\A\[[^\]]*\]\s*/, "").sub(/\A\d{3,5}\s+/, "").strip
  end

  private

  def parse_date(v)
    return v if v.is_a?(Date)
    return nil if v.blank?

    s = v.to_s
    s.match?(%r{\A\d{2}/\d{2}/\d{4}\z}) ? Date.strptime(s, "%m/%d/%Y") : Date.iso8601(s)
  rescue ArgumentError
    nil
  end
end
