require 'test_helper'

class AdminLeaderboardTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "admin-#{SecureRandom.hex(4)}@example.com",
      password: 'password12345',
      password_confirmation: 'password12345',
      roles: ['admin']
    )

    @month = Date.new(2096, 5, 1)
    @pass = InvoicePass.create!(start_of_month: @month)
    client = ForecastClient.create!(
      forecast_id: rand(1..2_000_000_000),
      name: "Leaderboard Client #{SecureRandom.hex(2)}"
    )
    @tracker = InvoiceTracker.create!(
      forecast_client: client,
      invoice_pass: @pass,
      qbo_account: qbo_accounts(:one)
    )
  end

  def contributor_with_payout(email, amount)
    person = ForecastPerson.create!(
      forecast_id: rand(1..2_000_000_000),
      email: email,
      data: {}
    )
    contributor = Contributor.create!(forecast_person: person)
    ContributorPayout.new(
      ledger: Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: contributor),
      invoice_tracker: @tracker,
      created_by: @admin,
      amount: amount
    ).save!(validate: false)
    contributor
  end

  test 'renders the ledger with the month, ranked earners and amounts' do
    alpha = contributor_with_payout('alpha@example.com', 900)
    contributor_with_payout('beta@example.com', 400)
    sign_in @admin

    get '/admin/leaderboard'

    assert_response :success
    assert_includes response.body, 'May 2096', 'shows the month heading'
    assert_includes response.body, 'alpha@example.com'
    assert_includes response.body, 'beta@example.com'
    assert_includes response.body, '$900.00'
    assert_includes response.body, '$1,300.00', 'shows the month total'
    assert_includes response.body, '$650.00', 'shows the average of the listed earners'
    assert_includes response.body, 'avg of top 2'
    assert_includes response.body, 'index_table', 'uses the shared ActiveAdmin table styling'
    assert_includes response.body, 'nag pill complete', 'marks the active limit toggle'
    assert_includes response.body,
      %(<a href="/admin/contributors/#{alpha.id}">alpha@example.com</a>),
      'links each contributor through to their contributor page'
  end

  test 'defaults to the top 5 and honors ?limit=' do
    7.times { |i| contributor_with_payout("earner#{i}@example.com", (i + 1) * 100) }
    sign_in @admin

    get '/admin/leaderboard'
    assert_response :success
    # Highest five are 700..300; the 200 and 100 earners fall outside the default.
    assert_includes response.body, 'earner6@example.com'
    assert_includes response.body, 'earner2@example.com'
    refute_includes response.body, 'earner1@example.com', 'defaults to top 5'

    get '/admin/leaderboard?limit=7'
    assert_response :success
    assert_includes response.body, 'earner0@example.com', 'limit=7 widens the board'
  end

  test 'clamps an out-of-range limit instead of erroring' do
    contributor_with_payout('solo@example.com', 100)
    sign_in @admin

    get '/admin/leaderboard?limit=99999'
    assert_response :success

    get '/admin/leaderboard?limit=bogus'
    assert_response :success
    assert_includes response.body, 'solo@example.com'
  end

  test 'non-admins are redirected away' do
    non_admin = AdminUser.create!(
      email: "plain-#{SecureRandom.hex(4)}@example.com",
      password: 'password12345',
      password_confirmation: 'password12345',
      roles: []
    )
    sign_in non_admin

    get '/admin/leaderboard'

    assert_response :redirect
    refute_includes(response.body.to_s, 'alpha@example.com')
  end
end
