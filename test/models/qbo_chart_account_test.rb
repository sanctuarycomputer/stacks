require "test_helper"

class QboChartAccountTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @qa = qbo_accounts(:one)
  end

  test "display_label includes acct_num when present" do
    row = QboChartAccount.create!(
      qbo_account: @qa, qbo_id: "10", name: "Bonuses", acct_num: "5710", data: {},
    )
    assert_equal "Bonuses (5710)", row.display_label
  end

  test "display_label is just the name when acct_num is blank" do
    row = QboChartAccount.create!(qbo_account: @qa, qbo_id: "11", name: "Contractors - Client Services", data: {})
    assert_equal "Contractors - Client Services", row.display_label
  end

  test "current_balance reads from data jsonb, defaulting to 0" do
    row = QboChartAccount.create!(qbo_account: @qa, qbo_id: "12", name: "Checking", data: { "current_balance" => 1234.5 })
    assert_equal 1234.5, row.current_balance
    bare = QboChartAccount.create!(qbo_account: @qa, qbo_id: "13", name: "Bare", data: nil)
    assert_equal 0.0, bare.current_balance
  end

  test "(qbo_account_id, qbo_id) must be unique" do
    QboChartAccount.create!(qbo_account: @qa, qbo_id: "14", name: "A", data: {})
    assert_raises(ActiveRecord::RecordNotUnique) do
      QboChartAccount.insert_all!([{ qbo_account_id: @qa.id, qbo_id: "14", name: "B", active: true }])
    end
  end
end
