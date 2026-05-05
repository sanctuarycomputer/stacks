# TODO: Deel integration
# TODO: Tests

class InvoiceTracker < ApplicationRecord
  belongs_to :admin_user, optional: true
  belongs_to :invoice_pass
  belongs_to :forecast_client, class_name: "ForecastClient", foreign_key: "forecast_client_id", primary_key: "forecast_id"

  belongs_to :qbo_invoice, class_name: "QboInvoice", foreign_key: "qbo_invoice_id", primary_key: "qbo_id", optional: true

  has_many :contributor_payouts, dependent: :destroy

  def display_name
    "#{qbo_invoice.try(:display_name) || forecast_client.name} (#{status})"
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

  def total
    (value || blueprint_total).try(:to_f)
  end

  def blueprint_total
    ((blueprint || {})["lines"] || []).reduce(0){|acc, l| acc += l[1]["quantity"]*l[1]["unit_price"]}
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
        qbo_invoice.status
      end
    end
  end

  def sent?
    qbo_invoice&.email_status == "EmailSent"
  end

  def forecast_project_ids
    return [] if blueprint.nil?
    blueprint["lines"].values.map{|l| l["forecast_project"]}
  end

  def project_trackers
    return @_project_trackers if defined?(@_project_trackers)

    ids = forecast_project_ids.compact
    @_project_trackers =
      if ids.empty?
        []
      else
        tracker_ids = ProjectTrackerForecastProject
          .where(forecast_project_id: ids)
          .distinct
          .pluck(:project_tracker_id)
        ProjectTracker.where(id: tracker_ids).includes(:forecast_projects).to_a
      end
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

  def make_blueprint!
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
      description = self.class.line_description_for(project, person, invoice_pass.invoice_month)
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
  end

  # Canonical QBO invoice line description, including a trailing [FP-<forecast_id>]
  # tag. The tag:
  # - de-duplicates lines for different people who share a name on the same project
  # - gives us a content-based fallback / cross-check against blueprint metadata
  # - survives QBO-side edits of OTHER fields on the line
  # The tag looks like a tracking ref to clients; they can ignore it.
  def self.line_description_for(project, person, invoice_month)
    base = "#{project.code} #{project.name} (#{invoice_month}) #{person.first_name} #{person.last_name}".strip
    "#{base} [FP-#{person.forecast_id}]"
  end

  # Pulls the forecast_person id encoded into a QBO line description by
  # line_description_for, or nil if the description is untagged (legacy lines
  # written before this format was introduced).
  def self.forecast_person_id_from_description(description)
    match = description.to_s.match(/\[FP-(\d+)\]\s*\z/)
    match && match[1].to_i
  end

  def changes_in_forecast
    return [] if blueprint.nil?
    # Strip the [FP-<id>] tag on both sides so legacy blueprints (without the tag)
    # still diff cleanly against freshly-generated blueprints (with the tag).
    strip_tag = ->(desc) { desc.to_s.sub(/\s*\[FP-\d+\]\s*\z/, "") }
    latest_lines = (make_blueprint![:lines] || {}).deep_stringify_keys.reduce({}) do |acc, (k, v)|
      acc[strip_tag.call(k)] = v.except("id")
      acc
    end
    blueprinted_lines = (blueprint["lines"] || {}).reduce({}) do |acc, (k, v)|
      acc[strip_tag.call(k)] = v.except("id")
      acc
    end

    Hashdiff.diff(blueprinted_lines, latest_lines)
  end

  def surplus_chunks
    contributor_payouts.includes(contributor: :forecast_person).map(&:calculate_surplus).flatten
  end

  def commission_deductions_for_line(project_tracker, qbo_line_item, blueprint_line)
    project_tracker.commissions.map do |commission|
      {
        commission: commission,
        amount: commission.deduction_for_line(qbo_line_item, blueprint_line).to_f.round(2),
      }
    end.reject { |d| d[:amount] <= 0 }
  end

  def commission_total_for_line(line_item_id)
    contributor_payouts.includes(:contributor).sum do |cp|
      (cp.blueprint["Commission"] || []).sum do |entry|
        entry.dig("blueprint_metadata", "id").to_s == line_item_id.to_s ? entry["amount"].to_f : 0
      end
    end
  end

  def surplus(chunks = surplus_chunks)
    chunks.sum{|c| c[:surplus]}
  end

  def n2c(*args, **kwargs, &b)
    ActionController::Base.helpers.number_to_currency(*args, **kwargs, &b)
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

          # Internal projects may or may not have a ProjectTracker. If they do
          # and it has commissions, deduct them off the top before recording the IC entry.
          ptfps = ProjectTrackerForecastProject.includes(:project_tracker).where(forecast_project_id: metadata["forecast_project"])
          pt = ptfps.first&.project_tracker
          commission_total = 0
          if pt
            deductions = commission_deductions_for_line(pt, line_item, metadata)
            commission_total = deductions.sum { |d| d[:amount] }

            deductions.each do |d|
              recipient = d[:commission].contributor.forecast_person
              next unless recipient.present?
              payouts[recipient] ||= {
                blueprint: {
                  AccountLead: [],
                  ProjectLead: [],
                  IndividualContributor: [],
                  Commission: [],
                }
              }
              payouts[recipient][:blueprint][:Commission] << {
                blueprint_metadata: ContributorPayout.slim_metadata(metadata),
                amount: d[:amount],
                description_line: d[:commission].description_line(line_item, metadata, d[:amount]),
              }
            end
          end

          payouts[individual_contributor] ||= {
            blueprint: {
              AccountLead: [],
              ProjectLead: [],
              IndividualContributor: [],
              Commission: [],
            }
          }
          payouts[individual_contributor][:blueprint][:IndividualContributor] << {
            blueprint_metadata: ContributorPayout.slim_metadata(metadata),
            amount: (line_item["amount"].to_f - commission_total).round(2),
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

        working_amount = line_item["amount"].to_f
        working_hours = metadata["quantity"].to_f
        working_rate = metadata["unit_price"].to_f

        # Commission deduction: take commissions off the top before AL/PL/IC math.
        deductions = commission_deductions_for_line(pt, line_item, metadata)
        commission_total = deductions.sum { |d| d[:amount] }
        working_amount -= commission_total

        deductions.each do |d|
          recipient = d[:commission].contributor.forecast_person
          next unless recipient.present?
          payouts[recipient] ||= {
            blueprint: {
              AccountLead: [],
              ProjectLead: [],
              IndividualContributor: [],
              Commission: [],
            }
          }
          payouts[recipient][:blueprint][:Commission] << {
            blueprint_metadata: ContributorPayout.slim_metadata(metadata),
            amount: d[:amount],
            description_line: d[:commission].description_line(line_item, metadata, d[:amount]),
          }
        end

        is_first_month_of_new_deal = invoice_pass.start_of_month == Date.new(2025, 6, 1)
        if is_first_month_of_new_deal
          working_hours =
            ForecastAssignment
              .where(
                'end_date >= ? AND start_date <= ? AND project_id = ? AND person_id = ?',
                Date.new(2025, 6, 16),
                Date.new(2025, 6, 30),
                metadata["forecast_project"],
                metadata["forecast_person"]
              ).map do |a|
                a.allocation_during_range_in_hours(Date.new(2025, 6, 16), Date.new(2025, 6, 30))
              end.compact.sum
          working_amount = working_hours * working_rate
          working_amount -= commission_total  # re-apply commission deduction after first-month recompute
        end

        account_lead = pt.account_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
        if account_lead.present?
          payouts[account_lead] ||= {
            blueprint: {
              AccountLead: [],
              ProjectLead: [],
              IndividualContributor: [],
              Commission: [],
            }
          }

          amount = (working_amount * 0.08).round(2)
          payouts[account_lead][:blueprint][:AccountLead] << {
            blueprint_metadata: ContributorPayout.slim_metadata(metadata),
            amount: amount,
            description_line: "- #{working_hours} hrs * #{n2c(working_rate)} p/h * 8% = #{n2c(amount)}",
          }
        end

        project_lead = pt.project_lead_for_month(invoice_pass.start_of_month).try(:forecast_person)
        if project_lead.present?
          payouts[project_lead] ||= {
            blueprint: {
              AccountLead: [],
              ProjectLead: [],
              IndividualContributor: [],
              Commission: [],
            }
          }
          amount = (working_amount * 0.05).round(2)
          payouts[project_lead][:blueprint][:ProjectLead] << {
            blueprint_metadata: ContributorPayout.slim_metadata(metadata),
            amount: amount,
            description_line: "- #{working_hours} hrs * #{n2c(working_rate)} p/h * 5% = #{n2c(amount)}",
          }
        end

        individual_contributor = ForecastPerson.find(metadata["forecast_person"])
        hourly_rate_of_pay_override = forecast_project.hourly_rate_override_for_email_address(individual_contributor.email)

        if individual_contributor.present?
          payouts[individual_contributor] ||= {
            blueprint: {
              AccountLead: [],
              ProjectLead: [],
              IndividualContributor: [],
              Commission: [],
            }
          }
          if hourly_rate_of_pay_override.present?
            amount = (working_hours * hourly_rate_of_pay_override).round(2)
            payouts[individual_contributor][:blueprint][:IndividualContributor] << {
              blueprint_metadata: ContributorPayout.slim_metadata(metadata),
              amount: amount,
              description_line: "- #{working_hours} hrs * #{n2c(hourly_rate_of_pay_override)} p/h = #{n2c(amount)}",
            }
          else
            amount = (working_amount * (1 - pt.company_treasury_split - (account_lead.present? ? 0.08 : 0) - (project_lead.present? ? 0.05 : 0))).round(2)
            payouts[individual_contributor][:blueprint][:IndividualContributor] << {
              blueprint_metadata: ContributorPayout.slim_metadata(metadata),
              amount: amount,
              description_line: "- #{working_hours} hrs * #{n2c(working_rate)} p/h * #{100 * (1 - pt.company_treasury_split - (account_lead.present? ? 0.08 : 0) - (project_lead.present? ? 0.05 : 0))}% = #{n2c(amount)}",
            }
          end
        end
      end

      synced = payouts.map do |payee, payee_data|
        amount = payee_data[:blueprint].values.flatten.sum{|l| l[:amount]}.round(2)
        next if amount == 0
        forecast_person = payee.is_a?(ForecastPerson) ? payee : payee.forecast_person
        forecast_person.ensure_contributor_exists!
        contributor = forecast_person.contributor

        # Only schedule payouts for variable hours people, as they're likely on the new deal
        if forecast_person.admin_user.nil? || forecast_person.admin_user.full_time_periods.empty? || forecast_person.admin_user.full_time_period_at(invoice_pass.start_of_month.end_of_month).variable_hours?
          cp = contributor_payouts.with_deleted.find_or_initialize_by(contributor: contributor)
          cp.update!(
            deleted_at: nil,
            amount: amount,
            blueprint: payee_data[:blueprint],
            created_by: created_by,
            description: "",
            accepted_at: payee.admin_user.present? ? nil : DateTime.now
          )
          next cp
        end
      end.compact

      (contributor_payouts - synced).each(&:destroy)
      contributor_payouts.reload

      # Commission-only CPs auto-accept: no contributor is reviewing their own work,
      # since the commission rate was agreed up-front on the project tracker.
      contributor_payouts.each do |cp|
        bp = cp.blueprint || {}
        commission_amount = (bp["Commission"] || []).sum { |e| e["amount"].to_f }
        other_amount = ["AccountLead", "ProjectLead", "IndividualContributor"].sum do |role|
          (bp[role] || []).sum { |e| e["amount"].to_f }
        end
        if commission_amount > 0 && other_amount == 0 && cp.accepted_at.nil?
          cp.update_columns(accepted_at: DateTime.now)
        end
      end

      # Assign splits for Surplus
      chunks = surplus_chunks.select{|c| c[:surplus] > 0}
      chunks.each do |c|
        next unless c[:project_tracker].present?

        lead_share = (c[:surplus] * 0.15).round(2)

        # Share to Account Lead
        account_lead = c[:project_tracker].account_lead_for_month(invoice_pass.start_of_month)
        account_lead_on_new_deal = account_lead ? (account_lead.full_time_periods.empty? || account_lead.full_time_period_at(invoice_pass.start_of_month.end_of_month).variable_hours?) : false
        if account_lead_on_new_deal && account_lead_contributor = account_lead.try(:forecast_person).try(:contributor)
          cp = contributor_payouts.with_deleted.find_or_initialize_by(contributor: account_lead_contributor)

          new_blueprint = (cp.blueprint || {}).clone
          new_blueprint["AccountLead"] ||= []
          new_blueprint["AccountLead"] << {
            amount: lead_share,
            description_line: "- #{n2c(c[:surplus])} * 15% = #{n2c(lead_share)} (`#{c[:qbo_line_item].dig("description")}` generated #{n2c(c[:surplus])} surplus revenue, 15% of which is shared with the Account Lead)",
            blueprint_metadata: ContributorPayout.slim_metadata(c[:blueprint_metadata]),
          }

          cp.update!(
            deleted_at: nil,
            amount: ((cp.amount || 0) + lead_share).round(2),
            blueprint: new_blueprint,
          )
        end

        # Share to Project Lead
        project_lead = c[:project_tracker].project_lead_for_month(invoice_pass.start_of_month)
        project_lead_on_new_deal = project_lead ? (project_lead.full_time_periods.empty? || project_lead.full_time_period_at(invoice_pass.start_of_month.end_of_month).variable_hours?) : false
        if project_lead_on_new_deal && project_lead_contributor = project_lead.try(:forecast_person).try(:contributor)
          cp = contributor_payouts.with_deleted.find_or_initialize_by(contributor: project_lead_contributor)

          new_blueprint = (cp.blueprint || {}).clone
          new_blueprint["ProjectLead"] ||= []
          new_blueprint["ProjectLead"] << {
            amount: lead_share,
            description_line: "- #{n2c(c[:surplus])} * 15% = #{n2c(lead_share)} (`#{c[:qbo_line_item].dig("description")})` generated #{n2c(c[:surplus])} surplus revenue, 15% of which is shared with the Project Lead)",
            blueprint_metadata: ContributorPayout.slim_metadata(c[:blueprint_metadata]),
          }

          cp.update!(
            deleted_at: nil,
            amount: ((cp.amount || 0) + lead_share).round(2),
            blueprint: new_blueprint,
          )
        end
      end

      contributor_payouts.reload.each do |cp|
        description =
          cp.blueprint.reduce("") do |acc, (role, data)|
            next acc if data.empty?
            acc << "# #{role.to_s.underscore.humanize}\n"
            acc << data.map{|vv| vv["description_line"]}.join("\n")
            acc << "\n\n"
            acc
          end

        description = description << "# Total: #{n2c(cp.amount)}"
        cp.update!(description: description)
      end

      contributor_payouts.reload
    end
  end

  # Retroactively updates the QBO item_ref on each line item of the attached QBO
  # invoice to reflect the CURRENT service-assignment logic in make_invoice!, without
  # touching id / quantity / amount / description. Useful when the person.studio →
  # qbo_item mapping (or the recurring-charge mapping) has changed and previously
  # generated invoices need to be brought in line.
  #
  # Returns a hash summary: { updated: [String], skipped: [String], unchanged: Integer }.
  # Raises if no QBO invoice is attached.
  def resync_qbo_line_item_services!
    raise "No QBO invoice attached" if qbo_invoice.nil?

    qbo_items, default_service_item = Stacks::Quickbooks.fetch_all_items

    access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token
    invoice_service = Quickbooks::Service::Invoice.new
    invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
    invoice_service.access_token = access_token

    live_invoice = invoice_service.fetch_by_id(qbo_invoice_id)

    blueprint_lines_by_id = (blueprint.is_a?(Hash) ? (blueprint["lines"] || {}).values : []).each_with_object({}) do |line, h|
      next unless line.is_a?(Hash) && line["id"]
      h[line["id"].to_s] = line
    end

    recurring_charges_by_description =
      RecurringCharge.where(forecast_client: forecast_client).index_by(&:description)

    updated = []
    skipped = []
    unchanged = 0
    any_changed = false

    live_invoice.line_items.each do |line_item|
      next unless line_item.sales_item? # skip subtotal / description-only lines

      description = line_item.description
      expected_item = nil

      if (bp_line = blueprint_lines_by_id[line_item.id.to_s])
        forecast_person_id = bp_line["forecast_person"]
        person = ForecastPerson.find_by(forecast_id: forecast_person_id)
        if person.nil?
          skipped << "#{description} — forecast_person ##{forecast_person_id} not found"
          next
        end
        expected_item = qbo_item_for_person(person, qbo_items, default_service_item)
      elsif (rc = recurring_charges_by_description[description])
        expected_item = qbo_items.find { |s| s.fully_qualified_name == rc.qbo_account_name } || default_service_item
      else
        skipped << "#{description} — unknown origin (not in blueprint or recurring charges)"
        next
      end

      current_item_ref = line_item.sales_line_item_detail.item_ref
      current_item_id = current_item_ref&.value.to_s
      if current_item_id == expected_item.id.to_s
        unchanged += 1
        next
      end

      line_item.sales_line_item_detail.item_id = expected_item.id
      updated << "#{description}: ##{current_item_id} → ##{expected_item.id} (#{expected_item.fully_qualified_name})"
      any_changed = true
    end

    if any_changed
      invoice_service.update(live_invoice)
      qbo_invoice.sync!
    end

    { updated: updated, skipped: skipped, unchanged: unchanged }
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

    qbo_inv.txn_date = invoice_pass.start_of_month.end_of_month

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
        item = qbo_item_for_person(person, qbo_items, default_service_item)

        description = self.class.line_description_for(project, person, invoice_pass.invoice_month)
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

    # Pepper in recurring charges. Don't add them to the blueprint.
    RecurringCharge.where(forecast_client: forecast_client).each do |rc|
      description = rc.description
      item =
        qbo_items.find { |s| s.fully_qualified_name == rc.qbo_account_name } || default_service_item

      line_item = qbo_inv.line_items.find do |qbo_li|
        qbo_li.description == description
      end

      unless line_item.present?
        line_item = Quickbooks::Model::InvoiceLineItem.new
        line_item.description = description
      end

      line_item.sales_item! do |detail|
        detail.unit_price = rc.unit_price
        detail.quantity = rc.quantity
        detail.item_id = item.id
      end

      line_item.amount =
        line_item.sales_line_item_detail.quantity * line_item.sales_line_item_detail.unit_price

      qbo_inv.line_items << line_item
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

  # Picks the QBO invoice-line Item for a given forecast_person. Mirrors the
  # bill-side internal-client override in ContributorPayout#find_qbo_account!:
  # for internal clients, when the person has no studio or is on a client-services
  # studio, force the line item's service to "Marketing Services" instead of the
  # studio's normal accounting_prefix-derived item.
  private def qbo_item_for_person(person, qbo_items, default_service_item)
    service_name = (person.studio.try(:accounting_prefix) || "").split(",").map(&:strip)[0]
    item = qbo_items.find { |s| s.fully_qualified_name == service_name } || default_service_item

    if forecast_client.is_internal? && (person.studio.nil? || person.studio.client_services?)
      marketing_item = qbo_items.find { |s| s.fully_qualified_name == MARKETING_SERVICES_ITEM_NAME }
      item = marketing_item if marketing_item.present?
    end

    item
  end

  # Fully qualified name of the QBO Item used for internal-client lines that would
  # otherwise resolve to a client-services studio service. Counterpart to the
  # "Contractors - Marketing Services" expense account used on the bill side.
  MARKETING_SERVICES_ITEM_NAME = "Marketing Services"
end
