# TODO: Deel integration
# TODO: Tests

class InvoiceTracker < ApplicationRecord
  include HasQboInvoiceViaCompositeKey

  belongs_to :admin_user, optional: true
  belongs_to :invoice_pass
  belongs_to :forecast_client, class_name: "ForecastClient", foreign_key: "forecast_client_id", primary_key: "forecast_id"

  # qbo_account is the direct binding — which of our QBO realms holds (or
  # will hold) this tracker's invoice. Set explicitly on every row; not
  # derived from forecast_client.billing_enterprise anymore (that conflated
  # "customer's enterprise mapping" with "issuer's qa", and broke when
  # Sanctuary historically billed sub-enterprises like garden3d).
  belongs_to :qbo_account
  belongs_to :qbo_invoice, class_name: "QboInvoice", foreign_key: "qbo_invoice_id", primary_key: "qbo_id", optional: true

  has_many :contributor_payouts, dependent: :destroy

  # Who last chose to generate this invoice's payouts over its cap, and why.
  # Set only by the admin "Generate anyway" action and cleared when a later
  # generation lands within the cap; not editable through the form.
  belongs_to :payout_cap_override_by, class_name: "AdminUser", optional: true

  delegate :billing_enterprise, to: :forecast_client

  # The share the company keeps on this invoice, when set by hand. nil means
  # "derive the cap from each project's billing model" (InvoicePayouts::Cap).
  # The only reader of the column: migrations here run by hand after the
  # deploy, so until then the row still carries company_treasury_split.
  def margin_override
    if has_attribute?(:target_margin_override)
      target_margin_override
    else
      self[:company_treasury_split]
    end
  end

  def display_name
    "#{qbo_invoice.try(:display_name) || forecast_client.name} (#{status})"
  end

  def qbo_invoice_link
    return nil unless qbo_invoice_id.present?
    "https://app.qbo.intuit.com/app/invoice?txnId=#{qbo_invoice_id}"
  end

  def blueprint_diff
    # deep_dup: a shallow clone shares the inner line hashes with the
    # blueprint attribute, so the [was, now] rewrites below would corrupt
    # the model's own blueprint and crash any second diff in the request.
    diff_base = blueprint.try(:deep_dup) || {
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
    return @_contributor_payouts_status if defined?(@_contributor_payouts_status)

    @_contributor_payouts_status =
      if !invoice_pass.allows_payment_splits?
        nil
      elsif contributor_payouts.loaded? ? contributor_payouts.any? : contributor_payouts.exists?
        (contributor_payouts.loaded? ? contributor_payouts.all?(&:accepted?) : contributor_payouts.where(accepted_at: nil).none?) ? :all_accepted : :some_pending
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

  # Batch-resolves project_trackers for a list of InvoiceTrackers using two
  # SQL round-trips total (down from 2 queries per tracker). Used by the
  # InvoicePass index, where surplus / value / etc. drag project_trackers
  # in for every tracker on every page. Result is memoized onto each
  # tracker's @_project_trackers so the per-instance method returns cache.
  def self.batch_preload_project_trackers!(invoice_trackers)
    list = Array(invoice_trackers).reject { |t| t.instance_variable_defined?(:@_project_trackers) }
    return if list.empty?

    ids_by_tracker = list.each_with_object({}) do |t, h|
      h[t] = t.forecast_project_ids.compact
    end
    all_fp_ids = ids_by_tracker.values.flatten.uniq
    if all_fp_ids.empty?
      list.each { |t| t.instance_variable_set(:@_project_trackers, []) }
      return
    end

    pt_by_fp_id = ProjectTrackerForecastProject
      .where(forecast_project_id: all_fp_ids)
      .pluck(:forecast_project_id, :project_tracker_id)
      .group_by(&:first)
      .transform_values { |rows| rows.map(&:last).uniq }

    all_pt_ids = pt_by_fp_id.values.flatten.uniq
    pts_by_id = ProjectTracker.where(id: all_pt_ids).includes(:forecast_projects).index_by(&:id)

    list.each do |t|
      pt_ids = ids_by_tracker[t].flat_map { |fp_id| pt_by_fp_id[fp_id] || [] }.uniq
      t.instance_variable_set(:@_project_trackers, pt_ids.filter_map { |pid| pts_by_id[pid] })
    end
  end

  def assignments
    # Filter by the client's forecast_project ids at the SQL level. The old
    # version loaded every assignment in the month into memory and then
    # did a Ruby select — fine in tests, ruinous in production where the
    # month-wide set is hundreds of thousands of rows. Also memoize within
    # the request so changes_in_forecast / make_blueprint! callers don't
    # re-query.
    return @_assignments if defined?(@_assignments)
    fp_ids = forecast_client.forecast_projects.pluck(:forecast_id)
    @_assignments =
      if fp_ids.empty?
        []
      else
        ForecastAssignment
          .includes(:forecast_person, forecast_project: :forecast_client)
          .where(project_id: fp_ids)
          .where(
            'end_date >= ? AND start_date <= ?',
            invoice_pass.start_of_month,
            invoice_pass.start_of_month.end_of_month,
          ).to_a
      end
  end

  def configuration_errors
    err = []
    qa = qbo_account
    err << [:missing_qbo_customer] if forecast_client.qbo_customer(qa: qa).nil?
    err << [:missing_qbo_term] if forecast_client.qbo_term(qa: qa).nil?
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
    # ContributorPayout's `:contributor` is delegated through `:ledger` (via
    # the LedgerItem concern), not a direct AR association — `.includes(contributor:)`
    # would raise AssociationNotFoundError. Eager-load through the actual chain.
    contributor_payouts.includes(ledger: { contributor: :forecast_person }).map(&:calculate_surplus).flatten
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
    # Same delegation gotcha as surplus_chunks — :contributor is a method
    # on CP, not an association. Eager-load via :ledger.
    contributor_payouts.includes(ledger: :contributor).sum do |cp|
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

  # The override columns arrive with a migration that is run by hand after
  # the deploy; until then there is nowhere to record one.
  def payout_cap_override_recordable?
    has_attribute?(:payout_cap_override_by_id)
  end

  def payout_cap_overridden?
    payout_cap_override_recordable? && payout_cap_override_at.present?
  end

  def record_payout_cap_override!(admin_user:, reason:, check:)
    return unless payout_cap_override_recordable?
    update!(
      payout_cap_override_by: admin_user,
      payout_cap_override_at: Time.current,
      payout_cap_override_reason: reason,
      payout_cap_override_payout_percentage: check.payout_percentage,
      payout_cap_override_cap_percentage: check.cap_percentage,
    )
  end

  def clear_payout_cap_override!
    return unless payout_cap_overridden?
    update!(
      payout_cap_override_by: nil,
      payout_cap_override_at: nil,
      payout_cap_override_reason: nil,
      payout_cap_override_payout_percentage: nil,
      payout_cap_override_cap_percentage: nil,
    )
  end

  class PayoutsOverCapError < StandardError; end

  # The build the last make_contributor_payouts! saved, which is not always
  # the one it was handed (see below).
  attr_reader :written_payout_build

  # Saves exactly what InvoicePayouts::Build computed. The per-payout cap
  # validation is skipped on every save here: it sums the tracker's payouts
  # mid-write, while stale ones from the last generation still exist. The
  # caller is expected to have run InvoicePayouts::MarginCheck on the build
  # first (the admin action does); called bare, this writes whatever the
  # build says, over the cap or not.
  #
  # The one thing a build cannot know in advance is which earlier payouts
  # the write can remove: it predicts that from the cached QBO bill, and the
  # delete then asks QBO. So the deletes go first, and if they disagree with
  # the prediction the build is recomputed from what actually survived
  # before anything is saved. A recomputed build that is over the cap raises
  # unless allow_over_cap.
  def make_contributor_payouts!(created_by, build: nil, allow_over_cap: false)
    raise "Payment splits are not supported for this invoice pass" unless invoice_pass.allows_payment_splits?
    return [] if qbo_invoice.nil?

    @written_payout_build = nil
    build ||= InvoicePayouts::Build.new(self)

    ActiveRecord::Base.transaction do
      # Per-row rescue around obsolete CP destroys: ContributorPayout's
      # before_destroy chain runs SyncsAsQboBill#detach_and_destroy_qbo_bill
      # which raises PaidQboBillError on a paid bill. Without this rescue
      # the exception would roll back the whole transaction. Skip the one
      # paid-bill orphan with a log; the rest of the tracker still updates.
      survivors = []
      build.orphan_candidates.each do |orphan|
        begin
          orphan.destroy
        rescue SyncsAsQboBill::PaidQboBillError => e
          survivors << orphan
          Rails.logger.error("[invoice_tracker_make_payouts] ##{id} cannot destroy orphan CP ##{orphan.id}: #{e.message}")
        end
      end

      predicted_ids = build.retained_orphans_before_surplus.map(&:id)
      survivor_ids = survivors.map(&:id)
      if survivor_ids.sort != predicted_ids.sort
        build = InvoicePayouts::Build.new(self, retained_orphan_ids: survivor_ids)
        if !allow_over_cap && InvoicePayouts::MarginCheck.new(build).breached?
          # Normally the unpredicted survivors are what tipped it over.
          blamed = (survivor_ids - predicted_ids).presence || survivor_ids
          raise PayoutsOverCapError,
            "Payouts would exceed the cap because an earlier payout (##{blamed.join(", #")}) could not be removed: its QBO bill has payments or could not be checked. No payouts were changed, though QBO bills of other removed payouts may already have been deleted and will be recreated on the next sync. Retry once QBO is reachable, or generate with a reason."
        end
      end

      # Everyone who earned something on this invoice gets a Contributor,
      # paid per invoice or not, as before.
      build.payees.each { |payee| payee.forecast_person.ensure_contributor_exists! if payee.amount != 0 }

      synced = build.paid_payees.map do |payee|
        forecast_person = payee.forecast_person
        forecast_person.ensure_contributor_exists!
        ledger = Ledger.find_or_create_for(enterprise: forecast_client.billing_enterprise, contributor: forecast_person.contributor)
        cp = contributor_payouts.with_deleted.find_or_initialize_by(ledger_id: ledger.id)
        preserve_acceptance =
          cp.persisted? && cp.accepted_at.present? && amount_equals?(cp.amount, payee.amount)

        attrs = {
          deleted_at: nil,
          amount: payee.amount,
          blueprint: payee.blueprint,
          created_by: created_by,
          description: "",
        }
        # Commission-only CPs (no admin_user behind them) auto-accept now and always.
        # Otherwise: preserve acceptance only when the recomputed amount matches the
        # existing one. Mismatches reset accepted_at so the contributor re-reviews.
        if forecast_person.admin_user.nil?
          attrs[:accepted_at] = DateTime.now
        elsif !preserve_acceptance
          attrs[:accepted_at] = nil
        end
        cp.skip_seventy_percent_check = true
        cp.update!(attrs)
        cp
      end

      # Anything still here that is neither paid nor a known survivor was not
      # a candidate when the build was computed (a payout added since). It
      # goes the same way; one that cannot is outside what the build counted.
      (contributor_payouts.reload.to_a - synced - survivors).each do |orphan|
        begin
          orphan.destroy
        rescue SyncsAsQboBill::PaidQboBillError => e
          Rails.logger.error("[invoice_tracker_make_payouts] ##{id} cannot destroy orphan CP ##{orphan.id}, which the build did not count: #{e.message}")
        end
      end

      # Commission-only CPs auto-accept: no contributor is reviewing their own work,
      # since the commission rate was agreed up-front on the project tracker.
      contributor_payouts.reload.each do |cp|
        bp = cp.blueprint || {}
        commission_amount = (bp["Commission"] || []).sum { |e| e["amount"].to_f }
        other_amount = ["AccountLead", "AccountLeadSurplus", "ProjectLead", "ProjectLeadSurplus", "IndividualContributor"].sum do |role|
          (bp[role] || []).sum { |e| e["amount"].to_f }
        end
        if commission_amount > 0 && other_amount == 0 && cp.accepted_at.nil?
          cp.update_columns(accepted_at: DateTime.now)
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
        cp.skip_seventy_percent_check = true
        cp.update!(description: description)
      end

      @written_payout_build = build
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

    qa = qbo_account
    raise "Billing enterprise (#{billing_enterprise.name}) has no connected QboAccount" if qa.nil?
    qbo_items, default_service_item = qa.fetch_all_items

    access_token = qa.make_and_refresh_qbo_access_token
    invoice_service = Quickbooks::Service::Invoice.new
    invoice_service.company_id = qa.realm_id
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
    # Defense-in-depth: InvoicePass#make_trackers! now filters internal
    # clients before creating InvoiceTrackers, but legacy rows may still
    # exist. Refuse to push a QBO invoice for one rather than silently
    # writing into the internal enterprise's QBO.
    if forecast_client.is_internal?
      raise "Refusing to invoice internal client #{forecast_client.name} — internal clients are paid via PayCycles, not InvoiceTrackers."
    end
    qa = qbo_account
    raise "Billing enterprise (#{billing_enterprise.name}) has no connected QboAccount" if qa.nil?
    qbo_items, default_service_item = qa.fetch_all_items

    customer = forecast_client.qbo_customer(qa: qa)
    term = forecast_client.qbo_term(qa: qa)
    qbo_inv = Quickbooks::Model::Invoice.new
    qbo_inv.customer_id = customer.id
    qbo_inv.private_note = invoice_pass.invoice_month
    qbo_inv.bill_email = customer.primary_email_address
    qbo_inv.sales_term_ref = Quickbooks::Model::BaseReference.new(
      term.name,
      value: term.id
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
    invoice_service.company_id = qa.realm_id
    invoice_service.access_token = qa.make_and_refresh_qbo_access_token
    created_qbo_inv = invoice_service.create(qbo_inv)

    # Assign Quickbooks Ids to our Internal Snapshot
    created_qbo_inv.line_items.reduce(snapshot) do |acc, qbo_li|
      line = acc[:lines][qbo_li.description]
      line[:id] = qbo_li.id if line.present?
      acc
    end

    # Create the local QboInvoice mirror first — the qbo_invoice_must_live_in_qbo_account
    # validation on this tracker checks that (qbo_account_id, qbo_invoice_id)
    # references a real row before the update! lands.
    ActiveRecord::Base.transaction do
      QboInvoice.find_or_create_by!(qbo_id: created_qbo_inv.id, qbo_account: qa)
      update!(qbo_invoice_id: created_qbo_inv.id, blueprint: snapshot)
    end
    self.reload
    created_qbo_inv
  end

  # Picks the QBO invoice-line Item for a given forecast_person.
  # For internal clients, when the person has no studio or is on a client-services
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

  private

  def amount_equals?(a, b)
    (a.to_f - b.to_f).abs <= 0.01
  end
end
