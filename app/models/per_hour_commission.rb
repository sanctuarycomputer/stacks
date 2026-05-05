class PerHourCommission < Commission
  def deduction_for_line(_qbo_line_item, blueprint_line)
    (blueprint_line["quantity"].to_f * rate.to_f).round(2)
  end

  def description_line(_qbo_line_item, blueprint_line, deduction)
    hrs = blueprint_line["quantity"].to_f
    "- #{hrs} hrs * #{n2c(rate)} p/h commission = #{n2c(deduction)} (commission to #{contributor.display_name})"
  end
end
