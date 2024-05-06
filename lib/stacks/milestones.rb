class Stacks::Milestones
  class << self

    def notion
      @_notion ||= Stacks::Notion.new
    end

    def sync!
      notion.sync_database(Stacks::Notion::DATABASE_IDS[:MILESTONES])
      notion.sync_database(Stacks::Notion::DATABASE_IDS[:TASKS])
    end
  end
end