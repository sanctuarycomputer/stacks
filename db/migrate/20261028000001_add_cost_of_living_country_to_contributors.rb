class AddCostOfLivingCountryToContributors < ActiveRecord::Migration[6.1]
  # These three were hardcoded to United States in PeriodicReport before the
  # column existed; carry that over so their profit shares don't change.
  US_EMAILS = %w[hugh@sanctuary.computer sohee@sanctuary.computer conan@sanctuary.computer].freeze

  def up
    # A Numbeo country name (a key of
    # PeriodicReport.parsed_numbeo_cost_of_living_indices_by_country). Set for
    # contributors who aren't on Deel; takes precedence over the Deel address.
    add_column :contributors, :cost_of_living_country, :string

    execute <<~SQL.squish
      UPDATE contributors SET cost_of_living_country = 'United States'
      FROM forecast_people
      WHERE forecast_people.forecast_id = contributors.forecast_person_id
        AND lower(forecast_people.email) IN (#{US_EMAILS.map { |e| connection.quote(e) }.join(", ")})
    SQL
  end

  def down
    remove_column :contributors, :cost_of_living_country
  end
end
