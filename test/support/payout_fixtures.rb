# Real rows for payout tests, with the QBO invoice stubbed on every
# InvoiceTracker instance (admin actions reload the tracker, so a stub on one
# object would be lost).
module PayoutFixtures
  def setup_payout_people
    Thread.current[:sanctuary_enterprise] = nil
    @pass = InvoicePass.find_or_create_by!(start_of_month: Date.new(2026, 8, 1), enterprise: Enterprise.sanctuary) { |ip| ip.data = {} }
    @client = ForecastClient.create!(forecast_id: 710_001, name: "Margin Guard Client")
    @project = ForecastProject.create!(forecast_id: 710_001, client_id: @client.forecast_id, name: "Guard Proj", code: "MG-1", tags: ["100p/h"])
    @ic = ForecastPerson.create!(forecast_id: 710_001, email: "ic-guard@example.com", data: {})
    @ic2 = ForecastPerson.create!(forecast_id: 710_005, email: "ic2-guard@example.com", data: {})
    @al_admin = AdminUser.create!(email: "al-guard@example.com", password: "password123", password_confirmation: "password123")
    @al = ForecastPerson.create!(forecast_id: 710_002, email: @al_admin.email, data: {})
    @pl_admin = AdminUser.create!(email: "pl-guard@example.com", password: "password123", password_confirmation: "password123")
    @pl = ForecastPerson.create!(forecast_id: 710_003, email: @pl_admin.email, data: {})
    @creator = AdminUser.create!(email: "creator-guard@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])
  end

  def build_tracker(model, project: @project)
    pt = ProjectTracker.new(name: "Guard Tracker #{model} #{project.forecast_id}", billing_model: model)
    pt.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: project)
    AccountLeadPeriod.create!(project_tracker: pt, admin_user: @al_admin, started_at: Date.new(2026, 8, 1))
    ProjectLeadPeriod.create!(project_tracker: pt, admin_user: @pl_admin, started_at: Date.new(2026, 8, 1))
    pt
  end

  # lines: [{ id: "1", person: @ic, project: @project, hours: 100.0, rate: 100.0 }, ...]
  def build_invoice_tracker(lines, total: nil)
    blueprint_lines = lines.each_with_object({}) do |l, h|
      project = l[:project] || @project
      h["#{project.code} line #{l[:id]} [FP-#{l[:person].forecast_id}]"] = {
        "id" => l[:id],
        "forecast_project" => project.forecast_id,
        "forecast_person" => l[:person].forecast_id,
        "quantity" => l[:hours],
        "unit_price" => l[:rate],
      }
    end
    it = InvoiceTracker.create!(
      forecast_client: @client,
      invoice_pass: @pass,
      qbo_account: qbo_accounts(:one),
      blueprint: { "generated_at" => DateTime.now.to_s, "lines" => blueprint_lines },
    )
    stub_qbo_invoice(lines, total: total)
    it
  end

  def stub_qbo_invoice(lines, total: nil)
    items = lines.map do |l|
      project = l[:project] || @project
      { "id" => l[:id], "amount" => (l[:hours] * l[:rate]).to_f, "description" => "#{project.code} line #{l[:id]} [FP-#{l[:person].forecast_id}]" }
    end
    qbo_invoice = mock("qbo_invoice")
    qbo_invoice.stubs(:line_items).returns(items)
    qbo_invoice.stubs(:data).returns({})
    qbo_invoice.stubs(:total).returns(total || items.sum { |i| i["amount"] })
    qbo_invoice.stubs(:display_name).returns("Guard Invoice")
    qbo_invoice.stubs(:status).returns(:unpaid)
    InvoiceTracker.any_instance.stubs(:qbo_invoice).returns(qbo_invoice)
    qbo_invoice
  end
end
