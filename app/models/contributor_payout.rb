class ContributorPayout < ApplicationRecord
  acts_as_paranoid
  include SyncsAsQboBill

  belongs_to :invoice_tracker
  belongs_to :contributor
  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id", primary_key: "forecast_id", optional: true
  belongs_to :created_by, class_name: 'AdminUser'
  belongs_to :qbo_bill, class_name: "QboBill", foreign_key: "qbo_bill_id", primary_key: "qbo_id", optional: true, dependent: :destroy

  # Ephemeral flag — not persisted. Set via the admin edit form to bypass the
  # 70% cap validation for a single save. Resets to nil on each fresh instance.
  attr_accessor :skip_seventy_percent_check

  validates :amount, presence: true
  validate :contributor_payouts_within_seventy_percent
  validate :only_after_new_deal

  def display_name
    inv_id = (invoice_tracker.qbo_invoice.try(:data) || {}).dig("doc_number")
    if inv_id.present?
      "#{invoice_tracker.forecast_client.name} (Inv ##{inv_id})"
    else
      "#{invoice_tracker.forecast_client.name}"
    end
  end

  def find_qbo_account!
    qbo_accounts = Stacks::Quickbooks.fetch_all_accounts
    account, studio = super(qbo_accounts)

    # If the client is not internal, we can use the original account
    internal_client = invoice_tracker.forecast_client.is_internal?
    return [account, studio] unless internal_client

    # If the client is internal, we need to override external client services accounts with the
    # marketing account
    marketing_account = qbo_accounts.find{|a| a.name == "Contractors - Marketing Services"}

    # In this case, either we don't know the studio, sor is present and it's a
    # client services studio, so we override to use the marketing account
    if studio.nil? || (studio.present? && studio.client_services?)
      return [marketing_account, studio]
    end

    # In this case, the studio is present but it's a non-client services studio
    # we assume that the original account is correct.
    [account, studio]
  end

  # jsonb normally returns a Hash; some legacy rows store a JSON string, or the setter
  # fell through to super(val) on JSON::ParserError and persisted Hash#inspect text.
  def blueprint
    self.class.coerce_blueprint_to_hash(read_attribute(:blueprint))
  end

  def blueprint=(val)
    super(val.is_a?(String) ? JSON.parse(val) : val)
  rescue JSON::ParserError
    super(val)
  end

  def self.coerce_blueprint_to_hash(raw)
    case raw
    when Hash
      raw
    when String
      coerce_blueprint_string(raw)
    else
      {}
    end
  end

  def self.coerce_blueprint_string(str)
    s = str.to_s.strip
    return {} if s.empty?

    parsed = parse_json_blueprint(s)
    return parsed if parsed

    # Hash-rocket text that JSON.parse rejects; keys/values are usually JSON-safe.
    if s.include?("=>")
      jsonish = s.gsub(/\s*=>\s*/, ":")
      parsed = parse_json_blueprint(jsonish)
      return parsed if parsed
    end

    {}
  end

  def self.parse_json_blueprint(s)
    parsed = JSON.parse(s)
    5.times { break unless parsed.is_a?(String); parsed = JSON.parse(parsed) }
    parsed if parsed.is_a?(Hash)
  rescue JSON::ParserError, TypeError
    nil
  end
  private_class_method :parse_json_blueprint

  # Fields preserved on blueprint entries:
  # - "id" → key into qbo_invoice.line_items for live surplus calc
  # - "forecast_project" → locate the ProjectTracker for surplus / monthly_cosr attribution
  # - "forecast_person" → diagnostic. On IC entries, MUST equal cp.contributor.forecast_person.forecast_id;
  #   drift signals a chunk has been moved or mismapped. On AL/PL entries, records the
  #   IC whose work generated the billable — useful audit context for lead shares.
  def self.slim_metadata(m)
    (m || {}).slice("id", "forecast_project", "forecast_person")
  end

  # Returns a slim copy of a blueprint hash: drops qbo_line_item and trims metadata
  # to just {id, forecast_project}. Preserves amount and description_line.
  def self.slim_blueprint(bp)
    return bp unless bp.is_a?(Hash)
    bp.transform_values do |entries|
      next entries unless entries.is_a?(Array)
      entries.map do |entry|
        next entry unless entry.is_a?(Hash)
        slim = entry.slice("amount", "description_line")
        if entry["blueprint_metadata"].is_a?(Hash)
          slim["blueprint_metadata"] = slim_metadata(entry["blueprint_metadata"])
        end
        slim
      end
    end
  end

  # Repoints a single blueprint entry to a different QBO line item without touching
  # `amount` or `description_line`. Used when a QBO invoice has been edited heavily
  # and the stored line item id on a chunk no longer resolves (or resolves to the
  # wrong line), causing calculate_surplus to compute against the wrong amount_billed.
  #
  # Also pulls forward `forecast_project` and `forecast_person` from the matching
  # invoice_tracker.blueprint["lines"] entry so all three diagnostic fields stay
  # aligned with the line the chunk now points at. An IC remap onto a line that
  # was originally for a different contributor will then surface via the
  # blueprint_integrity_errors check.
  #
  # Opportunistically slims the whole blueprint while we're writing — safe because
  # slim only drops unused fields and preserves every entry's `amount`.
  #
  # Raises if the role/index/new_line_item_id are invalid so the UI can surface the
  # error in a flash rather than silently no-op.
  def remap_blueprint_entry!(role:, index:, new_line_item_id:)
    bp = read_attribute(:blueprint)
    raise "Blueprint is not a hash" unless bp.is_a?(Hash)

    entries = bp[role]
    raise "Role #{role.inspect} not found in blueprint" unless entries.is_a?(Array)
    raise "Index #{index} out of bounds for #{role} (#{entries.length} entries)" unless (0...entries.length).cover?(index)

    new_id = new_line_item_id.to_s
    new_line = invoice_tracker.qbo_invoice&.line_items&.find { |li| li["id"].to_s == new_id }
    raise "QBO line item ##{new_id} not found on this invoice" unless new_line

    entry = entries[index]
    entry["blueprint_metadata"] ||= {}
    entry["blueprint_metadata"]["id"] = new_id

    # Pull forecast_project and forecast_person from the invoice_tracker blueprint's
    # line with the new id. If the QBO invoice has been edited so heavily that there's
    # no matching invoice_tracker line, leave those fields alone.
    it_lines = invoice_tracker.blueprint.is_a?(Hash) ? (invoice_tracker.blueprint["lines"] || {}).values : []
    it_line = it_lines.find { |l| l["id"].to_s == new_id }
    if it_line
      entry["blueprint_metadata"]["forecast_project"] = it_line["forecast_project"] if it_line["forecast_project"]
      entry["blueprint_metadata"]["forecast_person"] = it_line["forecast_person"] if it_line["forecast_person"]
    end

    slim_bp = self.class.slim_blueprint(bp)
    update_columns(blueprint: slim_bp)
    true
  end

  # Returns a list of human-readable strings describing integrity issues with the
  # blueprint. Empty list = clean. Currently only checks IndividualContributor entries,
  # where the stored forecast_person MUST equal this CP's contributor's forecast_person —
  # any mismatch means the chunk got muddled onto the wrong CP (via manual edit,
  # a botched remap, or a regen bug). Skipped for entries that lack the stored field
  # (legacy slimmed records before backfill).
  def blueprint_integrity_errors
    errs = []
    expected_fp = contributor&.forecast_person&.forecast_id
    return errs if expected_fp.nil?

    (blueprint["IndividualContributor"] || []).each_with_index do |ic, i|
      next unless ic.is_a?(Hash)
      stored_fp = ic.dig("blueprint_metadata", "forecast_person")
      next if stored_fp.blank?
      next if stored_fp.to_s == expected_fp.to_s

      errs << "IndividualContributor ##{i}: blueprint forecast_person (#{stored_fp}) does not match this payout's contributor forecast_person (#{expected_fp}) — chunk may be mismapped."
    end

    errs
  end

  # Migrates THIS payout's blueprint to the slim shape in place. Idempotent —
  # returns false if already slim (or not a hash). Returns true when a write happened.
  # Uses update_columns to skip validations, callbacks, and updated_at touch — this
  # is a storage cleanup, not a meaningful data change.
  def slim_blueprint!
    before = read_attribute(:blueprint)
    return false unless before.is_a?(Hash)

    after = self.class.slim_blueprint(before)
    return false if after == before

    # Safety: slimming must not alter total amounts for any role.
    sum = ->(h) { h.values.flatten.sum { |e| (e.is_a?(Hash) ? e["amount"] : 0).to_f }.round(2) }
    if sum.call(before) != sum.call(after)
      raise "slim_blueprint! would change total amounts on ContributorPayout ##{id} " \
            "(before=#{sum.call(before)} after=#{sum.call(after)})"
    end

    update_columns(blueprint: after)
    true
  end

  def calculate_surplus
    return [] unless in_sync?

    qbo_inv = invoice_tracker.qbo_invoice
    return [] unless qbo_inv.present?

    project_trackers = invoice_tracker.project_trackers

    blueprint["IndividualContributor"].map do |ic|
      blueprint_metadata = ic.dig("blueprint_metadata")
      qbo_line_item = qbo_inv.line_items.find{|li| li["id"] == blueprint_metadata.dig("id")} || {}
      amount_paid = ic.dig("amount").try(:to_f) || 0
      amount_billed = qbo_line_item.dig("amount").try(:to_f) || 0

      surplus = 0
      if amount_billed > 0
        profit_margin = (amount_billed - amount_paid) / amount_billed
        surplus = ((profit_margin - 0.43) * amount_billed).round(2)
        surplus = 0 if surplus <= 0
      end

      project_tracker = project_trackers.find{|pt| pt.forecast_project_ids.include?(blueprint_metadata.dig("forecast_project"))}
      {
        project_tracker: project_tracker,
        contributor: contributor,
        surplus: surplus,
        actual: amount_paid,
        maximum: 0.57 * amount_billed,
        chunk: ic,
        qbo_line_item: qbo_line_item,
        blueprint_metadata: blueprint_metadata,
      }
    end
  end

  def accrual_date
    invoice_tracker.invoice_pass.start_of_month.end_of_month
  end

  def toggle_acceptance!
    if accepted?
      raise "Cannot unaccept a payout if all payouts have been accepted." if invoice_tracker.contributor_payouts_status == :all_accepted
      update!(accepted_at: nil)
    else
      update!(accepted_at: DateTime.now)
    end
  end

  def accepted?
    accepted_at.present?
  end

  def payable?
    accepted? &&
    (invoice_tracker.status == :paid || (invoice_tracker.allow_early_contributor_payouts_on.present? && invoice_tracker.allow_early_contributor_payouts_on <= Date.today)) &&
    (invoice_tracker.contributor_payouts_status == :all_accepted)
  end

  def only_after_new_deal
    if invoice_tracker.invoice_pass.start_of_month < Stacks::System.singleton_class::NEW_DEAL_START_AT
      errors.add(:base, "Contributor Payouts can only be created for invoices sent after the New Deal began.")
    end
  end

  def status
    if deleted_at.present?
      "deleted"
    elsif blueprint.empty?
      "manual"
    else
      "calculated"
    end
  end

  def in_sync?
    begin
      blueprint_amount = (blueprint || {}).reduce(0) do |acc, (k, v)|
        acc += v.sum{|vv| vv["amount"].to_f}
        acc
      end
      blueprint_amount == amount
    rescue
      false
    end
  end

  def contributor_payouts_within_seventy_percent
    return if ActiveModel::Type::Boolean.new.cast(skip_seventy_percent_check) # Ephemeral admin override
    return if changes.keys == ["accepted_at"] # Don't check if the payout is being accepted or unaccepted

    cps = invoice_tracker.contributor_payouts.include?(self) ? invoice_tracker.contributor_payouts : [*invoice_tracker.contributor_payouts, self]

    if invoice_tracker.forecast_client.is_internal?
      max_amount = invoice_tracker.total
    else
      max_amount = invoice_tracker.total * (1 - invoice_tracker.company_treasury_split)
    end

    if cps.sum(&:amount) > (max_amount + 1) # Add a dollar to account for rounding errors
      errors.add(:base, "Contributor Payouts may not exceed #{ActionController::Base.helpers.number_to_currency(max_amount)} (#{100 * (1 - invoice_tracker.company_treasury_split)}% of invoice total).")
    end
  end

  def as_account_lead
    return 0 unless blueprint["AccountLead"].present?
    blueprint["AccountLead"].sum{|l| l["amount"]}
  end

  def as_project_lead
    legacy = blueprint["TeamLead"]
    current = blueprint["ProjectLead"]
    lines = [legacy, current].compact.flatten
    return 0 if lines.empty?
    lines.sum { |l| l["amount"].to_f }
  end

  def as_individual_contributor
    return 0 unless blueprint["IndividualContributor"].present?
    blueprint["IndividualContributor"].sum{|l| l["amount"]}
  end
end