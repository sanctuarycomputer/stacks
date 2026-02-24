class Contributor < ApplicationRecord
  default_scope -> { joins(:forecast_person).order("forecast_people.email ASC") }

  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id", primary_key: "forecast_id"
  belongs_to :qbo_vendor, class_name: "QboVendor", foreign_key: "qbo_vendor_id", primary_key: "qbo_id", optional: true
  belongs_to :deel_person, class_name: "DeelPerson", foreign_key: "deel_person_id", primary_key: "deel_id", optional: true

  has_many :misc_payments
  has_many :reimbursements
  has_many :contributor_payouts
  has_many :trueups

  # TODO: monthly ledger:
  # Payouts
  # Salary
  # Elevated Service?

  scope :recent_new_deal_contributors, -> {
    joins(:contributor_payouts).where("contributor_payouts.created_at > ?", 3.months.ago).distinct
  }

  def total_amount_paid
    d = {
      salary: 0,
      contract: contributor_payouts.sum(:amount),
      total: 0
    }

    if admin_user = forecast_person.try(:admin_user)
      ausw = admin_user.admin_user_salary_windows.all
      d = admin_user.full_time_periods.reduce({ salary: 0, contract: 0, total: 0 }) do |acc, ftp|
        next acc unless ftp.four_day? || ftp.five_day?
        ftp.started_at.upto(ftp.ended_at || Date.today).each do |date|
          days_in_month = Time.days_in_month(date.month, date.year)
          w = ausw.find{|sw| sw.start_date <= date && date <= (sw.end_date || Date.today) }
          next if w.nil?
          day_rate = w.salary / 12 / days_in_month
          acc[:salary] += day_rate
        end
        acc
      end
    end

    d[:total] = d[:salary] + d[:contract]
    d
  end

  def sync_qbo_bills!
    contributor_payouts.each do |cp|
      cp.sync_qbo_bill!
    end
  end

  def attempt_populate_qbo_vendor_and_deel_person!
    deel_people = DeelPerson.all
    qbo_vendors = QboVendor.all
    person = forecast_person

    first_name = person.data["first_name"].downcase
    last_name = person.data["last_name"].downcase

    deel_person = deel_people.find do |dp|
      dp_first_name, dp_last_name = dp.data["full_name"].split(" ")
      first_name == dp_first_name.downcase && last_name == dp_last_name.downcase
    end

    deel_emails = deel_person ? deel_person.data["emails"].map{|e| e["value"]}.compact : []

    qbo_vendor = qbo_vendors.find do |qv|
      if deel_emails.any?{|e| qv.display_name.downcase.include?(e.downcase)}
        true
      else
        qv.display_name.downcase.include?("#{first_name} #{last_name}")
      end
    end

    update(deel_person: deel_person, qbo_vendor: qbo_vendor)
  end

  def display_name
    forecast_person.email
  end

  def new_deal_balance(ledger_items = new_deal_ledger_items(false))
    ledger_items[:all].reduce({ balance: 0, unsettled: 0 }) do |acc, li|
      next acc if li.deleted_at.present?

      if li.is_a?(MiscPayment)
        acc[:balance] -= li.amount
      elsif li.is_a?(ContributorPayout)
        if li.payable?
          acc[:balance] += li.amount
        else
          acc[:unsettled] += li.amount
        end
      elsif li.is_a?(Reimbursement)
        if li.accepted?
          acc[:balance] += li.amount
        else
          acc[:unsettled] += li.amount
        end
      elsif li.is_a?(Trueup)
        acc[:balance] += li.amount
      end
      acc
    end
  end

  def self.aggregated_new_deal_balance
    all_misc_payments = MiscPayment.all
    all_contributor_payouts = ContributorPayout.includes(invoice_tracker: :invoice_pass).all
    all_reimbursements = Reimbursement.all
    all_trueups = Trueup.all

    ledger = all_contributor_payouts.reduce({ balance: 0, unsettled: 0 }) do |acc, cp|
      next acc if cp.invoice_tracker.invoice_pass.start_of_month > Date.today
      if cp.payable?
        acc[:balance] += cp.amount
      else
        acc[:unsettled] += cp.amount
      end
      acc
    end

    ledger = all_reimbursements.reduce(ledger) do |acc, r|
      next acc if r.created_at > Date.today
      if r.accepted?
        acc[:balance] += r.amount
      else
        acc[:unsettled] += r.amount
      end
      acc
    end

    ledger = all_trueups.reduce(ledger) do |acc, tu|
      next acc if tu.payment_date > Date.today
      acc[:balance] += tu.amount
      acc
    end

    ledger = all_misc_payments.reduce(ledger) do |acc, mp|
      next acc if mp.paid_at > Date.today
      acc[:balance] -= mp.amount
      acc
    end

    ledger
  end

  def new_deal_ledger_items(include_salary = true)
    preloaded_contributor_payouts = contributor_payouts.includes({ invoice_tracker: :invoice_pass }).with_deleted
    preloaded_misc_payments = misc_payments.with_deleted
    preloaded_reimbursements = reimbursements.with_deleted
    preloaded_trueups = trueups.includes(:invoice_pass).with_deleted

    ledger_ends_at = [*preloaded_misc_payments, *preloaded_contributor_payouts, *preloaded_trueups].reduce(Date.today) do |acc, li|
      if li.is_a?(MiscPayment)
        acc = li.paid_at if li.paid_at > acc
      elsif li.is_a?(ContributorPayout)
        acc = li.invoice_tracker.invoice_pass.start_of_month if li.invoice_tracker.invoice_pass.start_of_month > acc
      elsif li.is_a?(Reimbursement)
        acc = li.created_at if li.created_at > acc
      elsif li.is_a?(Trueup)
        acc = li.payment_date if li.payment_date > acc
      end
      acc
    end + 1.month

    ledger_starts_at = Stacks::System.singleton_class::NEW_DEAL_START_AT
    contiguous_ftps = []
    if admin_user = forecast_person.admin_user && forecast_person.admin_user
      ledger_starts_at = admin_user.start_date
      contiguous_ftps = admin_user.contiguous_full_time_periods_until(ledger_ends_at)
    end

    periods = Stacks::Period.for_gradation(:month, ledger_starts_at, ledger_ends_at).reverse
    periods.reduce({ all: [], by_month: {} }) do |acc, period|
      contributor_payouts_in_period = preloaded_contributor_payouts.select do |cp|
        cp.invoice_tracker.invoice_pass.start_of_month >= period.starts_at &&
        cp.invoice_tracker.invoice_pass.start_of_month <= period.ends_at
      end

      contractor_payouts_in_period = misc_payments.with_deleted.select do |cp|
        cp.paid_at >= period.starts_at &&
        cp.paid_at <= period.ends_at
      end

      reimbursements_in_period = reimbursements.with_deleted.select do |cp|
        cp.created_at >= period.starts_at &&
        cp.created_at <= period.ends_at
      end

      trueups_in_period = preloaded_trueups.select do |tu|
        tu.payment_date >= period.starts_at &&
        tu.payment_date <= period.ends_at
      end

      sorted = [*contributor_payouts_in_period, *contractor_payouts_in_period, *trueups_in_period, *reimbursements_in_period].sort do |a, b|

        date_a = nil
        if a.is_a?(Trueup)
          date_a = a.payment_date
        elsif a.is_a?(MiscPayment)
          date_a = a.paid_at
        elsif a.is_a?(Reimbursement)
          date_a = a.created_at
        elsif a.is_a?(ContributorPayout)
          date_a = a.invoice_tracker.invoice_pass.start_of_month
        end

        date_b = nil
        if b.is_a?(Trueup)
          date_b = b.payment_date
        elsif b.is_a?(MiscPayment)
          date_b = b.paid_at
        elsif b.is_a?(Reimbursement)
          date_b = b.created_at
        elsif b.is_a?(ContributorPayout)
          date_b = b.invoice_tracker.invoice_pass.start_of_month
        end

        date_b <=> date_a
      end

      acc[:all] = [*acc[:all], *sorted]

      total_hours = forecast_person.recorded_allocation_during_range_in_hours(period.starts_at, period.ends_at)
      total_income = (sorted.reduce(0) do |acc, item|
        if item.is_a?(Trueup)
          next acc += item.amount
        elsif item.is_a?(ContributorPayout)
          next acc += item.amount
        end
        acc
      end)

      ftp = nil
      partial_salary = 0
      if include_salary && admin_user.present?
        ftp = contiguous_ftps.find do |ftp|
          ftp[:started_at] <= period.starts_at && ftp[:ended_at] >= period.ends_at
        end

        broken_ftp = contiguous_ftps.find do |ftp|
          ftp[:started_at] <= period.starts_at && ftp[:ended_at] < period.ends_at && ftp[:ended_at].month == period.ends_at.month && ftp[:ended_at].year == period.ends_at.year
        end

        if ftp.nil? && broken_ftp.present?
          partial_salary = (period.starts_at..period.ends_at).reduce(0) do |acc, date|
            acc += admin_user.cost_of_employment_on_date(date, 1)
            acc
          end
        end
      end

      acc[:by_month][period] = {
        items: sorted,
        total_hours: total_hours,
        total_income: total_income,
        partial_salary: partial_salary,
        fulltime: ftp.present?,
        elevated_service: ftp.present? || (total_hours >= 120 || (partial_salary + total_income) >= 9000)
      }
      acc
    end
  end

end
