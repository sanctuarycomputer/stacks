module Qbo
  # One-time rollout backfill: ensure a monthly QboProfitAndLossReport row
  # exists for every calendar month in [from, through] (fetching missing ones
  # from QBO, throttled), then (re)project line items for each. Idempotent
  # and resumable — safe to re-run after a partial failure. Steady-state
  # maintenance afterwards is the find_or_fetch_for_range hook driven by the
  # nightly QboAccount#sync_all!.
  class BackfillMonthlyProfitAndLossReports
    def self.call(qbo_account:, from: Date.new(2020, 1, 1),
                  through: Date.today.last_month.end_of_month,
                  sleep_between_fetches: 1)
      summary = { existing: 0, fetched: 0, failed: [], line_item_reports: 0 }
      month = from.beginning_of_month

      while month <= through
        report = QboProfitAndLossReport.find_by(
          qbo_account: qbo_account, starts_at: month, ends_at: month.end_of_month
        )

        if report
          summary[:existing] += 1
        else
          begin
            report = QboProfitAndLossReport.find_or_fetch_for_range(
              month, month.end_of_month, false, qbo_account
            )
            summary[:fetched] += 1
            sleep(sleep_between_fetches)
          rescue StandardError => e
            Rails.logger.warn(
              "[Qbo::BackfillMonthlyProfitAndLossReports] #{month} failed: #{e.class} #{e.message}"
            )
            summary[:failed] << month
            report = nil
          end
        end

        if report
          begin
            if SyncProfitAndLossLineItems.call(report) == :synced
              summary[:line_item_reports] += 1
            end
          rescue StandardError => e
            Rails.logger.warn(
              "[Qbo::BackfillMonthlyProfitAndLossReports] #{month} line-item sync failed: #{e.class} #{e.message}"
            )
            summary[:failed] << month
          end
        end

        month = month.advance(months: 1)
      end

      summary
    end
  end
end
