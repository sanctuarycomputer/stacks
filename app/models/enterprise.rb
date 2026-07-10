class Enterprise < ApplicationRecord
  SANCTUARY_NAME = "Sanctuary Computer Inc".freeze
  GARDEN3D_NAME = "garden3d, LLC".freeze
  INDEX_SPACE_NAME = "Index Space, LLC".freeze
  USB_CLUB_NAME = "USB Club, LLC".freeze

  has_many :enterprise_forecast_clients, dependent: :destroy
  has_many :forecast_clients, through: :enterprise_forecast_clients
  has_many :ledgers
  has_many :pay_cycles, dependent: :destroy

  has_many :enterprise_admins, dependent: :destroy
  has_many :admin_users, through: :enterprise_admins

  accepts_nested_attributes_for :enterprise_forecast_clients, allow_destroy: true,
    reject_if: ->(attrs) { attrs[:forecast_client_id].blank? }
  accepts_nested_attributes_for :enterprise_admins, allow_destroy: true,
    reject_if: ->(attrs) { attrs[:admin_user_id].blank? }

  has_one :qbo_account
  accepts_nested_attributes_for :qbo_account, allow_destroy: true
  VERTICAL_MATCHER = /\[(.+)\](.*)/

  # When a new enterprise is created, every existing contributor immediately
  # gets a ledger for it. Pairs with Contributor.after_create so the
  # (contributor, enterprise) grid stays full on a long enough timeline.
  after_create :ensure_ledgers_for_all_contributors!

  def ensure_ledgers_for_all_contributors!
    Ledger.ensure_for_enterprise!(self)
  end

  # Returns a Date range to pre-fill a new PayCycle's starts_at/ends_at,
  # or nil if this enterprise hasn't been configured to run pay cycles.
  # "monthly"      → entire calendar month containing `date`
  # "twice_monthly" → 1..15 of `date`'s month if date.day <= 15, else 16..end_of_month
  def pay_cycle_default_range_for(date)
    case pay_cycle_cadence
    when "monthly"
      date.beginning_of_month..date.end_of_month
    when "twice_monthly"
      if date.day <= 15
        date.beginning_of_month..(date.beginning_of_month + 14)
      else
        (date.beginning_of_month + 15)..date.end_of_month
      end
    else
      nil
    end
  end

  def self.sanctuary
    Thread.current[:sanctuary_enterprise] ||= Enterprise.find_by!(name: SANCTUARY_NAME)
  end

  def self.garden3d
    Thread.current[:garden3d_enterprise] ||= Enterprise.find_by!(name: GARDEN3D_NAME)
  end

  def is_index?
    name == INDEX_SPACE_NAME
  end

  # Per-enterprise daily automation, dispatched by stacks:daily_enterprise_tasks.
  # Add new per-enterprise behaviors here rather than as new rake steps.
  def daily_tasks
    Stacks::Optix.deactivate_inactive_members! if is_index?
  end

  def discover_verticals
    qbo_account.qbo_profit_and_loss_reports.reduce([]) do |acc, qbo_profit_and_loss_report|
      # Legacy P&L rows may have an empty `data` hash (e.g., rows backfilled
      # from before the data column was being populated, or a sync that
      # bailed mid-write). `.dig` keeps the iteration safe.
      rows = qbo_profit_and_loss_report.data.dig("cash", "rows") || []
      rows.each do |row|
        splat = /\[(.+)\](.*)/.match(row[0])
        acc |= [splat[1]] if splat.present?
      end
      acc
    end
  end

  def generate_snapshot!
    verticals = discover_verticals.map(&:to_sym)
    snapshot =
      [:year, :month, :quarter, :trailing_3_months, :trailing_4_months, :trailing_6_months, :trailing_12_months].reduce({
        generated_at: DateTime.now.iso8601,
      }) do |acc, gradation|
        periods = Stacks::Period.for_gradation(gradation, Date.new(2023, 1, 1))
        acc[gradation] = Parallel.map(periods, in_threads: 1) do |period|
          prev_period = periods[0] == period ? nil : periods[periods.index(period) - 1]

          verticals.reduce({
            label: period.label,
            period_starts_at: period.starts_at.strftime("%m/%d/%Y"),
            period_ends_at: period.ends_at.strftime("%m/%d/%Y"),
            verticals: {
              All: {
                cash: {
                  datapoints: self.key_datapoints_for_period(period, prev_period, "cash", :All)
                },
                accrual: {
                  datapoints: self.key_datapoints_for_period(period, prev_period, "accrual", :All)
                },
              }
            }
          }) do |acc, vertical|
            acc[:verticals][vertical] = {
              cash: {
                datapoints: self.key_datapoints_for_period(period, prev_period, "cash", vertical)
              },
              accrual: {
                datapoints: self.key_datapoints_for_period(period, prev_period, "accrual", vertical)
              },
            }
            acc
          end

        end
        acc
      end
    update!(snapshot: snapshot)
  end

  def key_datapoints_for_period(period, prev_period, accounting_method, vertical)
    data = period.report(self.qbo_account).data_for_enterprise(self, accounting_method, period.label, vertical)
    prev_data = 
      prev_period.report(self.qbo_account).data_for_enterprise(self, accounting_method, prev_period.label, vertical) if prev_period.present?

    {
      revenue: {
        value: data[:revenue],
        unit: :usd,
        growth: (prev_data ? ((data[:revenue].to_f / prev_data[:revenue].to_f) * 100) - 100 : nil)
      },
      cogs: {
        value: data[:cogs],
        unit: :usd
      },
      expenses: {
        value: data[:expenses],
        unit: :usd
      },
      profit_margin: {
        value: data[:profit_margin],
        unit: :percentage
      },
    }
  end
end
