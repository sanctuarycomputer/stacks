class PercentageCommission < Commission
  validates :rate, numericality: { less_than_or_equal_to: 1 }

  def deduction_for_line(qbo_line_item, _blueprint_line)
    (qbo_line_item["amount"].to_f * rate.to_f).round(2)
  end

  def description_line(_qbo_line_item, blueprint_line, deduction)
    hrs = blueprint_line["quantity"].to_f
    rt  = blueprint_line["unit_price"].to_f
    "- #{hrs} hrs * #{n2c(rt)} p/h * #{(rate.to_f * 100).round(2)}% = #{n2c(deduction)} (commission to #{contributor.display_name})"
  end
end
