# Models that include this concern bust the Stacks::TaskBuilder cache
# whenever they're created, updated, or destroyed.
#
# The cache is just *cleared*, not rebuilt — the next request that calls
# Stacks::TaskBuilder.new.tasks (or .tasks_for / .task_count) triggers
# a single fresh build. So a transaction that touches many records (e.g.
# make_contributor_payouts!) only causes one rebuild on the next read,
# regardless of how many saves happened.
#
# Including a model here implies its changes can plausibly create, remove,
# or re-route a StacksTask. When in doubt: include it. The cost of an
# over-eager bust is one extra cache miss; the cost of an under-eager bust
# is users seeing stale tasks for up to 24h.
module BustsTaskCache
  extend ActiveSupport::Concern

  included do
    after_commit :bust_task_cache
    after_commit :bust_task_cache, on: :destroy
  end

  private

  def bust_task_cache
    Stacks::TaskBuilder.clear_cache!
  rescue => e
    # Cache failures should never break the underlying save.
    Rails.logger.error("BustsTaskCache failed for #{self.class.name}##{id}: #{e.class}: #{e.message}")
  end
end
