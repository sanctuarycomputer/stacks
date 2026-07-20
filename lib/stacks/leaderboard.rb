# Ranks contributors by how much they actually earned in each month.
#
# "Earnings" here means ContributorPayout only. Trueups are deliberately
# excluded: a Trueup is the mechanism that tops a leadership role up to the
# average of the top earners, so counting it would let the very roles being
# topped up appear at the top of the board they're benchmarked against.
# Because Trueups live in their own table (rather than as a type column on a
# shared ledger table), excluding them is structural — we simply never sum
# them — and no filtering predicate is required.
#
# A contributor has one Ledger per Enterprise, so payouts are grouped by
# ledgers.contributor_id to aggregate "across all their contributor ledgers".
# Months are bucketed on invoice_passes.start_of_month, matching the canonical
# dating used by ContributorPayout#effective_on_for_display.
require "csv"

module Stacks
  class Leaderboard
    DEFAULT_LIMIT = 5
    MIN_LIMIT = 1
    MAX_LIMIT = 50

    CSV_HEADERS = [
      "Month",
      "Rank",
      "Contributor",
      "Earnings",
      "Month Average",
      "Month Total",
    ].freeze

    Entry = Struct.new(:rank, :contributor_id, :display_name, :amount, keyword_init: true)

    # `average` is the mean across the listed entries only (not the whole
    # collective) — i.e. the "average top-N earner", which is the figure the
    # leadership compensation model multiplies against.
    MonthGroup = Struct.new(:start_of_month, :entries, :total, :average, keyword_init: true)

    # Coerces an untrusted ?limit= param into a sane integer.
    def self.sanitize_limit(raw)
      value = Integer(raw.to_s.strip, exception: false)
      return DEFAULT_LIMIT if value.nil?
      value.clamp(MIN_LIMIT, MAX_LIMIT)
    end

    def self.call(limit: DEFAULT_LIMIT)
      new(limit: limit).call
    end

    # Flat, spreadsheet-friendly rendering: one row per ranked contributor,
    # with the month's average and total repeated so the file pivots cleanly.
    # Amounts are unformatted decimals (no currency symbols or thousands
    # separators) so they land in a spreadsheet as numbers, not text.
    def self.to_csv(limit: DEFAULT_LIMIT, months: nil)
      groups = months || call(limit: limit)

      CSV.generate do |csv|
        csv << CSV_HEADERS
        groups.each do |group|
          group.entries.each do |entry|
            csv << [
              group.start_of_month.strftime("%Y-%m"),
              entry.rank,
              entry.display_name,
              format("%.2f", entry.amount),
              format("%.2f", group.average),
              format("%.2f", group.total),
            ]
          end
        end
      end
    end

    def initialize(limit: DEFAULT_LIMIT)
      @limit = limit
    end

    # Returns [MonthGroup] ordered most-recent month first.
    def call
      grouped = earnings_by_month_and_contributor
        .select { |_key, amount| amount.to_d.positive? }
        .group_by { |(month, _contributor_id), _amount| month }

      ranked_by_month = grouped.transform_values do |pairs|
        pairs
          .sort_by { |(_month, _contributor_id), amount| -amount.to_d }
          .first(@limit)
      end

      names = display_names_for(
        ranked_by_month.values.flatten(1).map { |(_month, contributor_id), _amount| contributor_id }.uniq
      )

      ranked_by_month
        .sort_by { |month, _pairs| month }
        .reverse
        .map do |month, pairs|
          entries = pairs.each_with_index.map do |((_month, contributor_id), amount), index|
            Entry.new(
              rank: index + 1,
              contributor_id: contributor_id,
              display_name: names.fetch(contributor_id, "Contributor ##{contributor_id}"),
              amount: amount.to_d
            )
          end

          total = entries.sum(&:amount)

          MonthGroup.new(
            start_of_month: month,
            entries: entries,
            total: total,
            average: entries.empty? ? BigDecimal(0) : (total / entries.size)
          )
        end
    end

    private

    # => { [start_of_month, contributor_id] => summed_amount }
    #
    # ContributorPayout is acts_as_paranoid, so its default scope already
    # excludes soft-deleted rows.
    def earnings_by_month_and_contributor
      ContributorPayout
        .joins(:ledger, invoice_tracker: :invoice_pass)
        .group("invoice_passes.start_of_month", "ledgers.contributor_id")
        .sum("contributor_payouts.amount")
    end

    def display_names_for(contributor_ids)
      return {} if contributor_ids.empty?

      # Contributor has a default_scope that force-joins forecast_person and
      # orders by email; unscoped keeps this lookup predictable.
      Contributor
        .unscoped
        .where(id: contributor_ids)
        .includes(:forecast_person)
        .each_with_object({}) do |contributor, memo|
          person = contributor.forecast_person
          full_name = [person&.first_name, person&.last_name].map(&:presence).compact.join(" ")
          memo[contributor.id] = full_name.presence || person&.email || "Contributor ##{contributor.id}"
        end
    end
  end
end
