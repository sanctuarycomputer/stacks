class Stacks::Perf
  attr_accessor :markers
  def initialize
    @last_marker_time = Time.now
    @markers = {}
  end

  def mark(label)
    now = Time.now
    elapsed = now - @last_marker_time
    @markers[label] = elapsed
    @last_marker_time = now
  end
end
