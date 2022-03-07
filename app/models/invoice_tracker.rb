# TODO: Malformed hourly rate?
# TODO: surface system errors
# TODO:
# I should be able to attach an invoice to a Project Tracker that's non-generated
# Deprecate old Automator stuff
# Ensure Automator flow is working with the new style

class InvoiceTracker < ApplicationRecord
  belongs_to :invoice_pass
  belongs_to :forecast_client, class_name: "ForecastClient", foreign_key: "forecast_client_id", primary_key: "forecast_id"

  attr_accessor :_qbo_invoice

  def display_name
    "#{forecast_client.name} - #{invoice_pass.invoice_month}"
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
      found = acc["lines"].values.find{|l| l["id"] == qbo_li.id}

      if found
        found["diff_state"] = "unchanged"
        binding.pry if qbo_li.sales_line_item_detail.nil?
        if found["quantity"].to_f != qbo_li.sales_line_item_detail.quantity
          found["diff_state"] = "changed"
          found["quantity"] = [found["quantity"].to_f, qbo_li.sales_line_item_detail.quantity]
        end
        if found["unit_price"].to_f != qbo_li.sales_line_item_detail.unit_price
          found["diff_state"] = "changed"
          found["unit_price"] = [found["unit_price"].to_f, qbo_li.sales_line_item_detail.unit_price]
        end
      else
        if qbo_li.sales_item?
          acc["lines"][qbo_li.description] = {
            "id" => qbo_li.id,
            "diff_state" => "added",
            "forecast_project" => nil,
            "forecast_person" => nil,
            "quantity" => qbo_li.sales_line_item_detail.quantity.to_f,
            "unit_price" => qbo_li.sales_line_item_detail.unit_price.to_f
          }
        end
      end

      acc
    end
  end

  def value
    qbo_invoice.try(:total)
  end

  def qbo_line_items_relating_to_forecast_projects(forecast_projects)
    base = blueprint.try(:clone) || {
      "generated_at" => DateTime.now.to_s,
      "lines" => {}
    }
    ((qbo_invoice.try(:line_items) || []).select do |qbo_li|
      forecast_projects
        .map(&:id)
        .include?((base["lines"].values.find{|l| l["id"] == qbo_li.id} || {})["forecast_project"])
    end || [])
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
          :not_sent
        end
      end
    end
  end

  def qbo_invoice
    if qbo_invoice_id.nil?
      @_qbo_invoice = nil
      return nil
    end
    begin
      @_qbo_invoice ||= Stacks::Quickbooks.fetch_invoice_by_id(qbo_invoice_id)
    rescue Quickbooks::IntuitRequestException => e
      @_qbo_invoice = nil
      if e.code == "610"
        update!(qbo_invoice_id: nil)
        return nil
      else
        raise e
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
        service_name = person.studio.try(:accounting_prefix)
        item =
          qbo_items.find { |s| s.fully_qualified_name == service_name } || default_service_item

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
        line_item.id = 9

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
    invoice_service.access_token = Stacks::Automator.make_and_refresh_qbo_access_token
    created_qbo_inv = invoice_service.create(qbo_inv)

    # Assign Quickbooks Ids to our Internal Snapshot
    created_qbo_inv.line_items.reduce(snapshot) do |acc, qbo_li|
      line = acc[:lines][qbo_li.description]
      line[:id] = qbo_li.id if line.present?
      acc
    end

    update!(qbo_invoice_id: created_qbo_inv.id, blueprint: snapshot)
    created_qbo_inv
  end

  # TODO: Remove me and associatged code
  def recover!(
    qbo_invoice_candidates = Stacks::Quickbooks.fetch_invoices_by_memo(invoice_pass.invoice_month)
  )
    return false if qbo_invoice_id.present?

    qbo_customer = forecast_client.qbo_customer
    return :missing_qbo_customer if qbo_customer.nil?

    qbo_invoice_candidate =
      qbo_invoice_candidates.find{|i| i.customer_ref.value == qbo_customer.id}
    # Invoice may have been deleted.
    return :no_candidate if qbo_invoice_candidate.nil?

    all_projects = ForecastProject.all
    all_people = ForecastPerson.all

    rebuilt_snapshot =
      qbo_invoice_candidate.line_items.reduce({
        generated_at: DateTime.now,
        lines: {}
      }) do |acc, qbo_li|
        next acc if qbo_li.id.nil?

        line = qbo_li.description
        project_code, person_full_name = line.split("(#{invoice_pass.invoice_month})")

        # Find Project
        project_code = project_code.gsub('[', '').gsub(']', '').strip

        # Handle case where these project names changed
        project_code = "APOL-1 Apollo Design" if project_code == "APOL-1 Apollo"
        project_code = "AIR-1 Air (Production)" if project_code == "AIR-1 Air Production"
        project_code = "AIR-1 Air" if project_code == "AIR-1 Air Design"

        project =
          all_projects.find do |p|
            "#{p.code} #{p.name}".gsub('[', '').gsub(']', '').strip == project_code.strip
          end

        # Ignore Shares Conversion from Light Phone projects
        next acc if project_code == "Shares Conversion"
        # Ignore Tablet Budget Cap
        next acc if project_code == "$15,600 Budget Cap"
        # Ignore Dims Font Purchase
        next acc if project_code == "Project Expense - Font Purchase"
        # Ignore these extra lines from the previous month
        if invoice_pass.invoice_month == "December 2021"
          next acc if project_code == "STRP-2 Charts (November 2021) Jake Hobart"
          next acc if project_code == "STRP-2 Charts (November 2021) James Musgrave"
        end

        binding.pry if project.nil?
        raise "No Project Found, Tracker: #{self.id}" if project.nil?

        acc[:lines][line] = {
          id: qbo_li.id,
          forecast_project: project.forecast_id,
          forecast_person: nil,
          quantity: qbo_li.sales_line_item_detail.quantity.to_f,
          unit_price: qbo_li.sales_line_item_detail.unit_price.to_f
        }

        # Attempt Find Person
        person =
          person_full_name && all_people.find do |p|
            "#{p.first_name} #{p.last_name}".strip == person_full_name.strip
          end
        acc[:lines][line][:forecast_person] = person.forecast_id if person.present?

        acc
      end

    update!(
      qbo_invoice_id: qbo_invoice_candidate.id,
      blueprint: rebuilt_snapshot
    )
  end
end
