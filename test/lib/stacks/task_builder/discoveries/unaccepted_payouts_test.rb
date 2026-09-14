require "test_helper"

class Stacks::TaskBuilder::Discoveries::UnacceptedPayoutsTest < ActiveSupport::TestCase
  setup do
    @enterprise = Enterprise.create!(name: "PayoutEnt-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "payout#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @admin = AdminUser.create!(email: "payoutadmin#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123", roles: ["admin"])

    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "PayoutClient-#{SecureRandom.hex(2)}")
    qbo_account = QboAccount.create!(name: "PayoutQBO-#{SecureRandom.hex(2)}", realm_id: SecureRandom.hex(6))
    ip = InvoicePass.create!(start_of_month: Date.current.beginning_of_month)
    @invoice_tracker = InvoiceTracker.create!(invoice_pass: ip, forecast_client: fc, qbo_account: qbo_account)
  end

  test "unaccepted payout produces one contributor task with ledger URL" do
    create_payout!(accepted_at: nil)

    tasks = discovery.tasks

    assert_equal 1, tasks.count { |task| task.type == :unaccepted_payouts && task.subject == @contributor }
    task = tasks.find { |task| task.type == :unaccepted_payouts }
    assert_equal Rails.application.routes.url_helpers.admin_contributor_path(@contributor, ledger: @ledger.id), task.subject_url
  end

  test "accepted payouts produce no task" do
    create_payout!(accepted_at: Time.current)

    refute discovery.tasks.any? { |task| task.type == :unaccepted_payouts }
  end

  test "multiple unaccepted payouts produce one contributor task" do
    2.times { create_payout!(accepted_at: nil) }

    assert_equal 1, discovery.tasks.count { |task| task.type == :unaccepted_payouts }
  end

  private

  def create_payout!(accepted_at:)
    ContributorPayout.create!(
      ledger: @ledger,
      invoice_tracker: @invoice_tracker,
      created_by: @admin,
      amount: 100,
      accepted_at: accepted_at,
    )
  end

  def discovery
    Stacks::TaskBuilder::Discoveries::UnacceptedPayouts.new(admin_fallback: [@admin])
  end
end
