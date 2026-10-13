# Whether a Problem or an Observation is a flag, and why. Both are Notion's
# call: the page's Flag property, a formula that gives the reason as text when
# the page is a flag and nothing when it is not. (A boolean formula or a
# checkbox is read too, and then there is no reason text.)
#
# What Notion states, flag or no flag, wins outright. Only a page whose synced
# data has no Flag property at all (it was synced before the property existed)
# falls back to the including class's interim_flag?.
#
# The SQL twin is Stacks::ProjectLog.flag_sql.
module Stacks::Notion::Flag
  PROPERTY = "Flag".freeze

  def flag?
    stated = Stacks::Notion::Props.flagged(notion_page.data, PROPERTY)
    stated.nil? ? interim_flag? : stated
  end

  # Notion did not say, so flag? is the interim rule's answer.
  def flag_inferred?
    Stacks::Notion::Props.flagged(notion_page.data, PROPERTY).nil?
  end

  # Notion's own sentence for why this is a flag, or nil when it gives none.
  def flag_reason
    Stacks::Notion::Props.formula_text(notion_page.data, PROPERTY).presence
  end
end
