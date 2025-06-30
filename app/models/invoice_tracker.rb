# TODO: Deel integration
# TODO: Tests

class InvoiceTracker < ApplicationRecord
  belongs_to :admin_user, optional: true
  belongs_to :invoice_pass
  belongs_to :forecast_client, class_name: "ForecastClient", foreign_key: "forecast_client_id", primary_key: "forecast_id"

  belongs_to :qbo_invoice, class_name: "QboInvoice", foreign_key: "qbo_invoice_id", primary_key: "qbo_id", optional: true

  has_many :contributor_payouts, dependent: :destroy

  def display_name
    "#{qbo_invoice.try(:display_name)}"
  end

  def qbo_invoice
    super || (qbo_invoice_id ? QboInvoice.create!(qbo_id: qbo_invoice_id) : nil)
  end

  def qbo_invoice_link
    return nil unless qbo_invoice_id.present?
    "https://app.qbo.intuit.com/app/invoice?txnId=#{qbo_invoice_id}"
  end

  def blueprint_diff
    diff_base = blueprint.try(:clone) || {
      "generated_at" => DateTime.now.to_s,
      "lines" => {}
    }
    diff_base["lines"].each do |description, l|
      l["diff_state"] = "removed"
    end

    (qbo_invoice.try(:line_items) || []).reduce(diff_base) do |acc, qbo_li|
      found = acc["lines"].values.find{|l| l["id"] == qbo_li["id"]}

      if found
        found["diff_state"] = "unchanged"
        if found["quantity"].to_f != qbo_li.dig("sales_line_item_detail", "quantity").to_f
          found["diff_state"] = "changed"
          found["quantity"] = [
            found["quantity"].to_f,
            qbo_li.dig("sales_line_item_detail", "quantity").to_f
          ]
        end
        if found["unit_price"].to_f != qbo_li.dig("sales_line_item_detail", "unit_price").to_f
          found["diff_state"] = "changed"
          found["unit_price"] = [
            found["unit_price"].to_f,
            qbo_li.dig("sales_line_item_detail", "unit_price").to_f
          ]
        end
      else
        if qbo_li.dig("detail_type") == "SalesItemLineDetail"
          acc["lines"][qbo_li["description"] || "No Description in Quickbooks"] = {
            "id" => qbo_li["id"],
            "diff_state" => "added",
            "forecast_project" => nil,
            "forecast_person" => nil,
            "quantity" => qbo_li.dig("sales_line_item_detail", "quantity").to_f,
            "unit_price" => qbo_li.dig("sales_line_item_detail", "unit_price").to_f
          }
        end
      end

      acc
    end
  end

  def value
    qbo_invoice.try(:total)
  end

  def balance
    qbo_invoice.try(:balance)
  end

  def qbo_line_items_relating_to_forecast_projects(forecast_projects)
    base = blueprint_diff.try(:clone) || {
      "generated_at" => DateTime.now.to_s,
      "lines" => {}
    }
    forecast_project_ids = forecast_projects.map(&:id)
    forecast_project_codes = forecast_projects.map{|fp| fp.code}.compact.uniq

    ((qbo_invoice.try(:line_items) || []).select do |qbo_li|
      corresponding_base_line_item = (base["lines"].values.find{|l| l["id"] == qbo_li["id"]} || {})

      if corresponding_base_line_item&.dig("forecast_project").present?
        forecast_project_ids.include?(corresponding_base_line_item["forecast_project"])
      else
        forecast_project_codes.any?{|code| (qbo_li["description"] || "").include?(code)}
      end
    end || [])
  end

  def contributor_payouts_status
    return nil unless invoice_pass.allows_payment_splits?
    if contributor_payouts.any?
      contributor_payouts.all?(&:accepted?) ? :all_accepted : :some_pending
    else
      :no_payouts
    end
  end

  def status
    if qbo_invoice.nil?
      if blueprint.nil?
        :not_made
      else
        :deleted
      end
    else
      if blueprint.nil?
        :impossible
      else
        if qbo_invoice.email_status == "EmailSent"
          overdue = (qbo_invoice.due_date - Date.today) < 0
          if qbo_invoice.balance == 0
            :paid
          elsif qbo_invoice.balance == qbo_invoice.total
            overdue ? :unpaid_overdue : :unpaid
          else
            overdue ? :partially_paid_overdue : :partially_paid
          end
        else
          if qbo_invoice.data["private_note"].downcase.include?("voided")
            :voided
          else
            :not_sent
          end
        end
      end
    end
  end

  def flush!
    update!(qbo_invoice_id: nil, blueprint: nil)
  end

  def forecast_project_ids
    return [] if blueprint.nil?
    blueprint["lines"].values.map{|l| l["forecast_project"]}
  end

  def project_trackers
    ProjectTracker
      .includes(:forecast_projects)
      .all
      .select{|pt| (pt.forecast_projects.map(&:forecast_id) & forecast_project_ids).any?}
  end

  def assignments
    ForecastAssignment
      .includes(:forecast_person)
      .includes(forecast_project: :forecast_client)
      .where(
        'end_date >= ? AND start_date <= ?',
        invoice_pass.start_of_month,
        invoice_pass.start_of_month.end_of_month
      ).select{|a| a.forecast_project.forecast_client == forecast_client}
  end

  def configuration_errors
    err = []
    qbo_customer = forecast_client.qbo_customer
    qbo_term = forecast_client.qbo_term
    err << [:missing_qbo_customer] if qbo_customer.nil?
    err << [:missing_qbo_term] if qbo_term.nil?
    err
  end

  def backfill_blueprint!
    snapshot =
      assignments.reduce({
        generated_at: DateTime.now,
        lines: {}
      }) do |acc, a|
        person = a.forecast_person
        project = a.forecast_project
        hours = a.allocation_during_range_in_hours(
          invoice_pass.start_of_month,
          invoice_pass.start_of_month.end_of_month
        )
        description =
          "#{project.code} #{project.name} (#{invoice_pass.invoice_month}) #{person.first_name} #{person.last_name}".strip
        acc[:lines][description] = acc[:lines][description] || {
          id: nil,
          forecast_project: project.forecast_id,
          forecast_person: person.forecast_id,
          quantity: 0,
          unit_price: project.hourly_rate,
        }
        acc[:lines][description][:quantity] += hours
        acc
      end
    update!(blueprint: snapshot)
  end

  def make_contributor_payouts!(created_by)
    raise "Payment splits are not supported for this invoice pass" unless invoice_pass.allows_payment_splits?
    return [] if qbo_invoice.nil?

    ActiveRecord::Base.transaction do
      payouts = {}

      qbo_invoice.line_items.each do |line_item|
        metadata = (blueprint["lines"] || {}).values.find{|l| l["id"] == line_item["id"]}
        next unless metadata.present?

        forecast_project = ForecastProject.includes(:forecast_client).find(metadata["forecast_project"])
        next unless forecast_project.present?

        # Handle Internal Project
        if forecast_project.forecast_client.is_internal?
          individual_contributor = ForecastPerson.find(metadata["forecast_person"])
          next unless individual_contributor.present?
          payouts[individual_contributor] ||= {
            blueprint: {
              AccountLead: [],
              TeamLead: [],
              IndividualContributor: []
            }
          }
          payouts[individual_contributor][:blueprint][:IndividualContributor] << {
            qbo_line_item: line_item,
            blueprint_metadata: metadata,
            amount: line_item["amount"].to_f,
          }
          next
        end

        # Handle Client Project
        ptfps = ProjectTrackerForecastProject.includes(:project_tracker).where(forecast_project_id: metadata["forecast_project"])
        if ptfps.length > 1
          raise "Multiple project trackers found for forecast project #{metadata["forecast_project"]}"
        end
        if ptfps.length == 0
          raise "No project trackers found for forecast project #{metadata["forecast_project"]}"
        end
        pt = ptfps.first.project_tracker

        account_lead = pt.account_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
        if account_lead.present?
          payouts[account_lead] ||= {
            blueprint: {
              AccountLead: [],
              TeamLead: [],
              IndividualContributor: []
            }
          }
          payouts[account_lead][:blueprint][:AccountLead] << {
            qbo_line_item: line_item,
            blueprint_metadata: metadata,
            amount: line_item["amount"].to_f * 0.08
          }
        end

        team_lead = pt.team_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
        if team_lead.present?
          payouts[team_lead] ||= {
            blueprint: {
              AccountLead: [],
              TeamLead: [],
              IndividualContributor: []
            }
          }
          payouts[team_lead][:blueprint][:TeamLead] << {
            qbo_line_item: line_item,
            blueprint_metadata: metadata,
            amount: line_item["amount"].to_f * 0.05
          }
        end

        individual_contributor = ForecastPerson.find(metadata["forecast_person"])

        if individual_contributor.present?
          payouts[individual_contributor] ||= {
            blueprint: {
              AccountLead: [],
              TeamLead: [],
              IndividualContributor: []
            }
          }
          payouts[individual_contributor][:blueprint][:IndividualContributor] << {
            qbo_line_item: line_item,
            blueprint_metadata: metadata,
            amount: line_item["amount"].to_f * (1 - pt.company_treasury_split - (account_lead.present? ? 0.08 : 0) - (team_lead.present? ? 0.05 : 0)),
          }
        end
      end

      synced = payouts.map do |payee, payee_data|
        amount = payee_data[:blueprint].values.flatten.sum{|l| l[:amount]}
        next if amount == 0
        cp = contributor_payouts.with_deleted.find_or_initialize_by(
          forecast_person: payee.is_a?(ForecastPerson) ? payee : payee.forecast_person,
        )
        cp.update!(
          deleted_at: nil,
          amount: amount.round(2),
          blueprint: payee_data[:blueprint],
          created_by: created_by
        )
        cp
      end

      (contributor_payouts - synced).each(&:destroy)
    end
  end

  def description_from_blueprint(blueprint)
    blueprint.reduce("") do |acc, (role, data)|

      acc << "#{role.to_s}\n"
      if data.empty?
        acc << "No time in role\n\n"
        next acc
      end
      #acc << "#{description} (#{data[:quantity]} hours @ #{data[:unit_price]}/hour)\n"
      acc
    end
  end

  def make_invoice!
    return if configuration_errors.any?
    return if qbo_invoice.present?
    qbo_items, default_service_item = Stacks::Quickbooks.fetch_all_items

    qbo_inv = Quickbooks::Model::Invoice.new
    qbo_inv.customer_id = forecast_client.qbo_customer.id
    qbo_inv.private_note = invoice_pass.invoice_month
    qbo_inv.bill_email = forecast_client.qbo_customer.primary_email_address
    qbo_inv.sales_term_ref = Quickbooks::Model::BaseReference.new(
      forecast_client.qbo_term.name,
      value: forecast_client.qbo_term.id
    )
    qbo_inv.allow_online_ach_payment = true
    qbo_inv.customer_memo =
      Stacks::System.singleton_class::DEFAULT_CUSTOMER_MEMO

    snapshot =
      assignments.reduce({
        generated_at: DateTime.now,
        lines: {}
      }) do |acc, a|
        person = a.forecast_person
        project = a.forecast_project
        hours = a.allocation_during_range_in_hours(
          invoice_pass.start_of_month,
          invoice_pass.start_of_month.end_of_month
        )
        service_name = person.studio.try(:accounting_prefix) || ""
        service_name = service_name.split(",").map(&:strip)[0]
        item =
          qbo_items.find { |s| s.fully_qualified_name == "#{service_name} Services" } || default_service_item

        description =
          "#{project.code} #{project.name} (#{invoice_pass.invoice_month}) #{person.first_name} #{person.last_name}".strip
        line_item = qbo_inv.line_items.find do |qbo_li|
          qbo_li.description == description
        end

        unless line_item.present?
          line_item = Quickbooks::Model::InvoiceLineItem.new
          line_item.description = description
          qbo_inv.line_items << line_item
        end

        if line_item.sales_item?
          line_item.sales_line_item_detail.quantity += hours
        else
          line_item.sales_item! do |detail|
            detail.unit_price = project.hourly_rate
            detail.quantity = hours
            detail.item_id = item.id
          end
        end
        line_item.amount =
          line_item.sales_line_item_detail.quantity * line_item.sales_line_item_detail.unit_price

        acc[:lines][description] = acc[:lines][description] || {
          id: nil,
          forecast_project: project.forecast_id,
          forecast_person: person.forecast_id,
          quantity: 0,
          unit_price: line_item.sales_line_item_detail.unit_price.to_f,
        }
        acc[:lines][description][:quantity] =
          line_item.sales_line_item_detail.quantity.to_f
        acc
      end

    invoice_service = Quickbooks::Service::Invoice.new
    invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
    invoice_service.access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token
    created_qbo_inv = invoice_service.create(qbo_inv)

    # Assign Quickbooks Ids to our Internal Snapshot
    created_qbo_inv.line_items.reduce(snapshot) do |acc, qbo_li|
      line = acc[:lines][qbo_li.description]
      line[:id] = qbo_li.id if line.present?
      acc
    end

    update!(qbo_invoice_id: created_qbo_inv.id, blueprint: snapshot)
    QboInvoice.create!(qbo_id: created_qbo_inv.id)
    self.reload
    created_qbo_inv
  end
end
