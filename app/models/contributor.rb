class Contributor < ApplicationRecord
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id", primary_key: "forecast_id"
  belongs_to :qbo_vendor, class_name: "QboVendor", foreign_key: "qbo_vendor_id", primary_key: "qbo_id", optional: true
  belongs_to :deel_person, class_name: "DeelPerson", foreign_key: "deel_person_id", primary_key: "deel_id", optional: true

  has_many :misc_payments
  has_many :contributor_payouts
  has_many :trueups

  # TODO: monthly ledger:
  # Payouts
  # Salary
  # Elevated Service?

  scope :recent_new_deal_contributors, -> {
    joins(:contributor_payouts).where("contributor_payouts.created_at > ?", 3.months.ago).distinct
  }

  def sync_qbo_bills!
    # ForecastPerson.all.find{|fp| fp.email == "zachary@sanctuary.computer"}.contributor.sync_qbo_bills!
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

  def misc_payments_in_date_range(start_date, end_date)
    misc_payments
      .joins({ invoice_tracker: :invoice_pass })
      .where('invoice_passes.start_of_month >= ? AND invoice_passes.start_of_month <= ?', start_date, end_date)
      .distinct
  end

  def new_deal_balance(ledger_items = new_deal_ledger_items())
    new_deal_ledger_items[:all].reduce({ balance: 0, unsettled: 0 }) do |acc, li|
      next acc if li.deleted_at.present?

      if li.is_a?(MiscPayment)
        acc[:balance] -= li.amount
      elsif li.is_a?(ContributorPayout)
        if li.payable?
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

  def new_deal_ledger_items
    preloaded_contributor_payouts = contributor_payouts.includes({ invoice_tracker: :invoice_pass }).with_deleted
    preloaded_misc_payments = misc_payments.with_deleted
    preloaded_trueups = trueups.includes(:invoice_pass).with_deleted

    latest_date = [*preloaded_misc_payments, *preloaded_contributor_payouts, *preloaded_trueups].reduce(Date.today) do |acc, li|
      if li.is_a?(MiscPayment)
        acc = li.paid_at if li.paid_at > acc
      elsif li.is_a?(ContributorPayout)
        acc = li.invoice_tracker.invoice_pass.start_of_month if li.invoice_tracker.invoice_pass.start_of_month > acc
      elsif li.is_a?(Trueup)
        acc = li.payment_date if li.payment_date > acc
      end
      acc
    end

    periods = Stacks::Period.for_gradation(:month, Stacks::System.singleton_class::NEW_DEAL_START_AT, latest_date + 1.month).reverse
    periods.reduce({ all: [], by_month: {} }) do |acc, period|
      contributor_payouts_in_period = preloaded_contributor_payouts.select do |cp|
        cp.invoice_tracker.invoice_pass.start_of_month >= period.starts_at &&
        cp.invoice_tracker.invoice_pass.start_of_month <= period.ends_at
      end

      contractor_payouts_in_period = misc_payments.with_deleted.select do |cp|
        cp.paid_at >= period.starts_at &&
        cp.paid_at <= period.ends_at
      end

      trueups_in_period = preloaded_trueups.select do |tu|
        tu.payment_date >= period.starts_at &&
        tu.payment_date <= period.ends_at
      end

      sorted = [*contributor_payouts_in_period, *contractor_payouts_in_period, *trueups_in_period].sort do |a, b|

        date_a = nil
        if a.is_a?(Trueup)
          date_a = a.payment_date
        elsif a.is_a?(MiscPayment)
          date_a = a.paid_at
        elsif a.is_a?(ContributorPayout)
          date_a = a.invoice_tracker.invoice_pass.start_of_month
        end

        date_b = nil
        if b.is_a?(Trueup)
          date_b = b.payment_date
        elsif b.is_a?(MiscPayment)
          date_b = b.paid_at
        elsif b.is_a?(ContributorPayout)
          date_b = b.invoice_tracker.invoice_pass.start_of_month
        end

        date_b <=> date_a
      end

      acc[:all] = [*acc[:all], *sorted]
      acc[:by_month][period] = sorted
      acc
    end
  end

end
