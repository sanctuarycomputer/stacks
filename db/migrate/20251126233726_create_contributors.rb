class CreateContributors < ActiveRecord::Migration[6.1]
  def change
    create_table :contributors do |t|
      t.references :forecast_person, null: false
      t.references :qbo_vendor
      t.string :deel_person_id
      t.timestamps
    end

    ForecastPerson.all.each do |person|
      person.ensure_contributor_exists!
    end
  end
end
