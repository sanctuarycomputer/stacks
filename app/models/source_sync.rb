class SourceSync < ApplicationRecord
  belongs_to :system_task, optional: true

  def self.for(source)
    create_or_find_by!(source: source.to_s)
  end

  def advance!(cursor: nil, stats: nil, status: 'success')
    self.cursor = cursor if cursor
    self.stats = stats if stats
    self.status = status
    self.last_run_at = Time.current
    save!
  end
end
