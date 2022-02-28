class InvoiceTracker < ApplicationRecord
  belongs_to :invoice_pass
  belongs_to :forecast_client, class_name: "ForecastClient", foreign_key: "forecast_client_id", primary_key: "forecast_id"

  def display_name
    "#{forecast_client.name} - #{invoice_pass.invoice_month}"
  end

  def qbo_invoice
    return nil if qbo_invoice_id.nil?
    Stacks::Quickbooks.fetch_invoice_by_id(qbo_invoice_id)
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

  def recover!(
    qbo_invoice_candidates = Stacks::Quickbooks.fetch_invoices_by_memo(invoice_pass.invoice_month)
  )
    return if qbo_invoice_id.present?

    qbo_invoice_candidates =
      Stacks::Quickbooks.fetch_invoices_by_memo(invoice_pass.invoice_month)

    qbo_customer = forecast_client.qbo_customer
    raise "No QBO Customer Found, Tracker: #{self.id}" if qbo_customer.nil?

    qbo_invoice_candidate =
      qbo_invoice_candidates.find{|i| i.customer_ref.value == qbo_customer.id}
    # Invoice may have been deleted.
    return if qbo_invoice_candidate.nil?

    all_projects = ForecastProject.all
    all_people = ForecastPerson.all

    rebuilt_blueprint =
      qbo_invoice_candidate.line_items.reduce({
        generated_at: DateTime.now,
        lines: {}
      }) do |acc, qbo_line|
        next acc if qbo_line.id.nil?

        line = qbo_line.description
        project_code, person_full_name = line.split(/\s\(.+\)\s?/)

        # Find Project
        project_code = project_code.gsub('[', '').gsub(']', '')
        project =
          all_projects.find do |p|
            "#{p.code} #{p.name}".gsub('[', '').gsub(']', '').strip == project_code.strip
          end

        # Ignore Shares Conversion from Light Phone projects
        next acc if project_code == "Shares Conversion"
        # Ignore Tablet Budget Cap
        next acc if project_code == "$15,600 Budget Cap"
        # Handle case where this project name changed
        project_code = "APOL-1 Apollo Design" if project_code == "APOL-1 Apollo"

        # TODO:
        # I should be able to attach an invoice to a Project Tracker that's non-generated
        # It should work with forecast project names that have parens ()
        # I should see the amount from this invoice that's related to my project tracker on that page
        # Allow wether or not to show ICs on invoices as setting
        # Deprecate old Automator stuff
        # Ensure Automator flow is working with the new style
        # Should we sync QBO things? Nah
        binding.pry if project.nil?
        raise "No Project Found, Tracker: #{self.id}" if project.nil?

        acc[:lines][line] = {
          forecast_project: project.forecast_id,
          forecast_person: nil,
          service: qbo_line.sales_line_item_detail.item_ref.name,
          allocation: qbo_line.sales_line_item_detail.quantity,
          hourly_rate: qbo_line.sales_line_item_detail.unit_price
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
      blueprint: rebuilt_blueprint
    )
  end


  def generate_blueprint!
    studios = Studio.all

    blueprint = assignments.reduce({ generated_at: DateTime.now, lines: {} }) do |acc, a|
      person = a.forecast_person
      project = a.forecast_project

      line = "#{project.code} #{project.name} (#{invoice_pass.invoice_month}) #{person.first_name} #{person.last_name}".strip
      acc[:lines][line] = acc[:lines][line] || {
        forecast_project: project.forecast_id,
        forecast_person: person.forecast_id,
        service:
          studios.find{|s| person.roles.include?(s.name)}.try(:accounting_prefix) || "Services",
        allocation: 0,
        hourly_rate: project.hourly_rate
      }
      acc[:lines][line][:allocation] += a.allocation_during_range_in_hours(
        invoice_pass.start_of_month,
        invoice_pass.start_of_month.end_of_month
      )
      acc
    end
  end
end
