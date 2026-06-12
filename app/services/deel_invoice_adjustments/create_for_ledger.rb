module DeelInvoiceAdjustments
  # Creates a DeelInvoiceAdjustment in Deel for a given ledger + contract,
  # then persists the response as a Stacks-side DIA.
  class CreateForLedger
    class Error < StandardError; end

    def self.call(ledger:, amount:, contract_id:, description:, date_submitted:, initiated_by:)
      new(ledger: ledger, amount: amount, contract_id: contract_id,
          description: description, date_submitted: date_submitted, initiated_by: initiated_by).call
    end

    def initialize(ledger:, amount:, contract_id:, description:, date_submitted:, initiated_by:)
      @ledger = ledger
      @amount = BigDecimal(amount.to_s)
      @contract_id = contract_id.to_s
      @description = description.to_s
      @date_submitted = date_submitted
      @initiated_by = initiated_by
    end

    def call
      parsed = call_deel_api
      raise Error, "Deel did not return an adjustment id" if parsed.dig("data", "id").blank?

      DeelInvoiceAdjustment.create_from_deel_response!(
        ledger: @ledger,
        deel_contract_id: @contract_id,
        amount: @amount,
        description: @description,
        date_submitted: @date_submitted,
        parsed_response: parsed,
      )
    rescue ActiveRecord::RecordInvalid => e
      raise Error, "Could not persist DIA: #{e.message}"
    end

    private

    # Calls the Deel invoice-adjustments API directly, matching the payload
    # structure from Contributors::SubmitDeelInvoiceAdjustment#call.
    def call_deel_api
      Stacks::Deel.create_invoice_adjustment!(
        amount: @amount,
        contract_id: @contract_id,
        description: @description,
        date_submitted: @date_submitted,
      )
    rescue Stacks::Deel::ApiError => e
      raise Error, e.message
    end
  end
end
