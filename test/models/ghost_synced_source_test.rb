require 'test_helper'

class GhostSyncedSourceTest < ActiveSupport::TestCase
  test "requires a unique source" do
    GhostSyncedSource.create!(source: "newsletter")
    dupe = GhostSyncedSource.new(source: "newsletter")
    assert_not dupe.valid?
    assert_not GhostSyncedSource.new(source: "").valid?
  end
end
