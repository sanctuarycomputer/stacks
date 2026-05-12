require "test_helper"

class LedgerTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)
    fp = ForecastPerson.create!(forecast_id: 991_001, email: "test@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
  end

  test "belongs to enterprise and contributor" do
    ledger = Ledger.create!(enterprise: @enterprise, contributor: @contributor)
    assert_equal @enterprise, ledger.enterprise
    assert_equal @contributor, ledger.contributor
  end

  test "(enterprise, contributor) is unique" do
    Ledger.create!(enterprise: @enterprise, contributor: @contributor)
    assert_raises(ActiveRecord::RecordInvalid) do
      Ledger.create!(enterprise: @enterprise, contributor: @contributor)
    end
  end

  test ".find_or_create_for finds existing or creates new" do
    ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    assert ledger.persisted?
    same = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    assert_equal ledger, same
  end
end
