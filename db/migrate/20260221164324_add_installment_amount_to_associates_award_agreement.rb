class AddInstallmentAmountToAssociatesAwardAgreement < ActiveRecord::Migration[6.1]
  def change
    add_column :associates_award_agreements, :installment_amount, :integer, default: 104_167
    add_column :associates_award_agreements, :contract_url, :string
  end
end
