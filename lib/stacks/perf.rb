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
    report
  end

  def report
    @markers.each{|k,v| puts "#{k}: #{v.round(2)} seconds"}
  end
end
