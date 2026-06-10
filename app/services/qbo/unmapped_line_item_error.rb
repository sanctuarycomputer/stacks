module Qbo
  # Raised when the bill account mapping engine can't resolve a QBO chart
  # account for a line item. Deliberately strict: there is NO fallback to
  # hard-coded routing. Fix by adding the missing QboBillAccountMapping
  # in admin (Enterprise → QBO Bill Account Mappings).
  class UnmappedLineItemError < StandardError; end
end
