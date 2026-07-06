
unless URI.respond_to?(:escape)
  module URI
    def self.escape(str, unsafe = nil)
      if unsafe
        URI::DEFAULT_PARSER.escape(str.to_s, unsafe)
      else
        URI::DEFAULT_PARSER.escape(str.to_s)
      end
    end
  end
end

unless URI.respond_to?(:unescape)
  module URI
    def self.unescape(str)
      URI::DEFAULT_PARSER.unescape(str.to_s)
    end
  end
end