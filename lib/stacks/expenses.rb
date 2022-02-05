class Stacks::Expenses
  class << self
    def fetch_all
      service = Quickbooks::Service::Purchase.new
      service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      service.access_token = Stacks::Automator.make_and_refresh_qbo_access_token
      service.all
    end

    def sync_all!
      purchases = Stacks::Expenses.fetch_all
      data = (purchases.map do |p|
        p.line_items.map do |pli|
          {
            id: "#{p.id}-#{pli.id}",
            txn_date: p.txn_date,
            qbo_purchase_id: p.id,
            description: pli.description,
            amount: pli.amount
          }
        end
      end).flatten
      QboPurchaseLineItem.upsert_all(data, unique_by: :id)
    end

    def match_all!
      groups = ExpenseGroup.all
      matchers = groups.map{|g| Regexp.new(g.matcher)}
      expenses = QboPurchaseLineItem.all

      expenses.each do |e|
        matching_groups =
          matchers
            .select{|m| m.match(e.description)}
            .map{|m| groups[matchers.index(m)]}
        if matching_groups.length == 1
          e.update!(
            expense_group: matching_groups.first,
            data: {}
          )
        elsif matching_groups.length > 1
          e.update!(
            expense_group: nil,
            data: {
              errors: {
                conflicting_expense_groups: matching_groups.map(&:id)
              }
            }
          )
        else
          e.update!(
            expense_group: nil,
            data: {}
          )
        end
      end

    end
  end
end
