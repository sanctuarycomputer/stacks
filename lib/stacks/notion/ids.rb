# Notion ids arrive dashed (API bodies) or as 32 hex chars (URLs, ntn, DATABASE_IDS).
# The mirror stores and looks up the dashed form everywhere.
module Stacks::Notion::Ids
  HEX32 = /\A[0-9a-f]{32}\z/.freeze

  def self.normalize(id)
    return nil if id.nil?
    hex = id.to_s.strip.downcase.delete("-")
    return nil unless hex.match?(HEX32)
    hex.unpack("A8 A4 A4 A4 A12").join("-")
  end

  def self.valid?(id)
    !normalize(id).nil?
  end
end
