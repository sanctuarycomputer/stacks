class Studio < ApplicationRecord
  def qbo_sales_category
    "[SC] #{accounting_prefix} Services"
  end

  def qbo_payroll_category
    "[SC] #{accounting_prefix} Payroll"
  end

  def qbo_benefits_category
    "[SC] #{accounting_prefix} Benefits, Contributions & Tax"
  end

  def qbo_expenses_category
    "[SC] #{accounting_prefix} Supplies & Materials"
  end

  def qbo_subcontractors_category
    "[SC] #{accounting_prefix} Subcontractors"
  end
end
