# Builders for garden3d management fee tests.
#
# There is a garden3d Enterprise fixture but no garden3d QboAccount fixture,
# and adding one would give every test that already creates its own two of
# them (has_one :qbo_account is unordered). So it is created here.
module ManagementFeeFixtures
  def clear_enterprise_memos
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
  end

  def garden3d
    enterprises(:garden3d)
  end

  def garden3d_qbo_account
    @garden3d_qbo_account ||= QboAccount.create!(
      enterprise: garden3d, realm_id: "g3d-#{SecureRandom.hex(4)}", client_id: "x", client_secret: "y",
    )
  end

  def garden3d_pass(month)
    InvoicePass.create!(start_of_month: month, enterprise: garden3d, data: {})
  end

  # A management fee payer with one internal Forecast client per forecast id.
  def make_payer(name, customer_id: nil, forecast_ids: [rand(1_000_000..2_000_000_000)])
    payer = Enterprise.find_by(name: name) || Enterprise.create!(name: name)
    payer.update!(management_fee_payer: true, g3d_qbo_customer_id: customer_id)
    forecast_ids.each do |forecast_id|
      ForecastClient.create!(forecast_id: forecast_id, name: "#{name} internal #{forecast_id}")
      EnterpriseForecastClient.create!(enterprise: payer, forecast_client_id: forecast_id)
    end
    payer
  end

  def fee_tracker(pass, payer)
    client_id = EnterpriseForecastClient
      .where(enterprise_id: payer.id).order(:forecast_client_id).pick(:forecast_client_id)
    InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client_id, qbo_account: garden3d_qbo_account)
  end

  # Attaches a mirrored QuickBooks invoice. The stored data is never blank:
  # QboInvoice#data fetches from QuickBooks when it is. Dated the last day of
  # the tracker's pass month, as push_invoice! dates a draft, unless told
  # otherwise.
  def attach_invoice(tracker, qbo_id:, total:, balance:, sent:, lines: nil, txn_date: nil)
    txn_date ||= tracker.invoice_pass.start_of_month.end_of_month
    mirror_invoice(tracker.qbo_account, qbo_id: qbo_id, total: total, balance: balance, sent: sent,
                                        lines: lines, txn_date: txn_date)
    tracker.update!(qbo_invoice_id: qbo_id)
    InvoiceTracker.find(tracker.id)
  end

  # A mirrored QuickBooks invoice attached to nothing, in the shape
  # push_invoice! stores (Quickbooks::Model::Invoice#as_json: the date is an
  # ISO String under "txn_date", the customer under "customer_ref").
  def mirror_invoice(qbo_account, qbo_id:, total:, balance:, sent:, txn_date:, customer_id: nil, lines: nil,
                     private_note: nil)
    data = {
      "id" => qbo_id,
      "total" => total,
      "balance" => balance,
      "email_status" => sent ? "EmailSent" : "NotSet",
      "due_date" => "2999-01-01",
      "txn_date" => txn_date.respond_to?(:iso8601) ? txn_date.iso8601 : txn_date,
      "line_items" => lines || [fee_line(total)],
    }
    data["customer_ref"] = { "value" => customer_id, "name" => "Customer #{customer_id}" } if customer_id
    data["private_note"] = private_note if private_note
    QboInvoice.create!(qbo_account: qbo_account, qbo_id: qbo_id, data: data)
  end

  def fee_line(amount, item: "Managerial Services")
    {
      "amount" => amount,
      "description" => "Management fee",
      "detail_type" => "SalesItemLineDetail",
      "sales_line_item_detail" => { "item_ref" => { "name" => item, "value" => "2" } },
    }
  end

  # --- QuickBooks ------------------------------------------------------------

  def qbo_item(id, name)
    Quickbooks::Model::Item.new.tap do |item|
      item.id = id
      item.fully_qualified_name = name
    end
  end

  def qbo_term(id, name, due_days)
    Quickbooks::Model::Term.new.tap do |term|
      term.id = id
      term.name = name
      term.due_days = due_days
    end
  end

  def qbo_customer(id, name)
    Quickbooks::Model::Customer.new.tap do |customer|
      customer.id = id
      customer.display_name = name
    end
  end

  def qbo_created_invoice(id, total: "0", balance: "0", email_status: "NotSet", private_note: nil, txn_date: nil)
    Quickbooks::Model::Invoice.new.tap do |invoice|
      invoice.id = id
      invoice.txn_date = txn_date if txn_date
      invoice.email_status = email_status
      invoice.total = BigDecimal(total)
      invoice.balance = BigDecimal(balance)
      invoice.private_note = private_note
      invoice.due_date = Date.new(2999, 1, 1)
    end
  end

  # What Quickbooks::Service::Invoice#query answers with.
  def qbo_collection(entries)
    Quickbooks::Collection.new.tap { |collection| collection.entries = entries }
  end

  # Stubs everything garden3d's QuickBooks would answer, and makes any write a
  # test did not ask for raise. A test that expects a write says so with its
  # own `expects`, which Mocha prefers over these stubs.
  #
  # `invoices_in_month` is what QuickBooks already holds for the customer in
  # the pass month: the pre-flight read push_invoice! makes before it writes.
  def stub_garden3d_qbo(items: nil, terms: nil, customers: [], invoices_in_month: [])
    items ||= [qbo_item("1", "Services"), qbo_item("2", "Managerial Services")]
    terms ||= [qbo_term("1", "Net 30", 30), qbo_term("2", "Net 15", 15)]
    default_item = items.find { |item| item.fully_qualified_name == "Services" }

    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token).returns(:access_token)
    QboAccount.any_instance.stubs(:fetch_all_items).returns([items, default_item])
    QboAccount.any_instance.stubs(:fetch_all_terms).returns(terms)
    QboAccount.any_instance.stubs(:fetch_all_customers).returns(customers)

    # The gem's access_token= rebuilds an HTTP connection from the token.
    Quickbooks::Service::Invoice.any_instance.stubs(:access_token=)
    Quickbooks::Service::Customer.any_instance.stubs(:access_token=)
    Quickbooks::Service::Invoice.any_instance.stubs(:query).returns(qbo_collection(invoices_in_month))
    Quickbooks::Service::Invoice.any_instance.stubs(:create)
      .raises(RuntimeError, "unexpected QuickBooks invoice write")
    Quickbooks::Service::Customer.any_instance.stubs(:create)
      .raises(RuntimeError, "unexpected QuickBooks customer write")
  end
end
